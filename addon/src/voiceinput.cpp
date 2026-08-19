#include "voiceinput.h"
#include "flutter_engine.h"
#include "popup_surface.h"
#include "funasr_local_engine.h"
#include "sherpa_engine.h"
#include "sherpa-onnx/c-api.h"
#include "funasr_ws_engine.h"

#include <fcitx-config/iniparser.h>
#include <fcitx-utils/keysym.h>
#include <fcitx-utils/log.h>
#include <fcitx/addonmanager.h>
#include <fcitx/inputcontextmanager.h>

#include <dbus_public.h>

#include <unistd.h>

#include <arpa/inet.h>
#include <dirent.h>
#include <sys/select.h>
#include <sys/socket.h>

#include <chrono>
#include <sstream>
#include <thread>

#include <fontconfig/fontconfig.h>
#include <fcitx-utils/standardpath.h>

namespace fcitx {

static uint64_t nowUs() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<uint64_t>(ts.tv_sec) * 1000000 + ts.tv_nsec / 1000;
}

// ---------------------------------------------------------------------------
// 部署健康检查 + 引擎切换联动（W1/W5）
// ---------------------------------------------------------------------------
// 扫 /proc 找 funasr 服务进程（匹配 funasr-server/server.py + 端口）
static pid_t findFunasrPid(int port, long *rssKb) {
    DIR *d = opendir("/proc");
    if (!d) {
        return -1;
    }
    pid_t found = -1;
    std::string portArg = "--port " + std::to_string(port) + " ";
    struct dirent *e;
    while ((e = readdir(d)) != nullptr) {
        if (e->d_name[0] < '0' || e->d_name[0] > '9') {
            continue;
        }
        std::string cl = "/proc/" + std::string(e->d_name) + "/cmdline";
        FILE *f = fopen(cl.c_str(), "r");
        if (!f) {
            continue;
        }
        std::string cmd;
        char buf[4096];
        size_t n = fread(buf, 1, sizeof(buf), f);
        fclose(f);
        for (size_t i = 0; i < n; ++i) {
            cmd += buf[i] ? buf[i] : ' ';
        }
        if (cmd.find("funasr-server/server.py") == std::string::npos) {
            continue;
        }
        if (port > 0 && cmd.find(portArg) == std::string::npos &&
            cmd.find("--port " + std::to_string(port)) == std::string::npos) {
            continue;
        }
        found = atoi(e->d_name);
        if (rssKb) {
            *rssKb = 0;
            std::string st = "/proc/" + std::string(e->d_name) + "/status";
            if (FILE *sf = fopen(st.c_str(), "r")) {
                char line[256];
                while (fgets(line, sizeof(line), sf)) {
                    if (strncmp(line, "VmRSS:", 6) == 0) {
                        *rssKb = atol(line + 6);
                        break;
                    }
                }
                fclose(sf);
            }
        }
        break;
    }
    closedir(d);
    return found;
}

// TCP 端口探测（funasrUrl 解析出的 host:port）
static bool portListening(const std::string &host, int port) {
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) {
        return false;
    }
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    if (inet_pton(AF_INET, host.c_str(), &addr.sin_addr) != 1) {
        close(fd);
        return false;
    }
    // 非阻塞 connect 即可探测（本地端口立刻返回）
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    int r = connect(fd, (sockaddr *)&addr, sizeof(addr));
    if (r != 0 && errno != EINPROGRESS) {
        close(fd);
        return false;
    }
    // EINPROGRESS 也算在听（内核 RST 才是没听）；极短等待确认可写
    fd_set w;
    FD_ZERO(&w);
    FD_SET(fd, &w);
    struct timeval tv{0, 50000};
    bool ok = false;
    if (select(fd + 1, nullptr, &w, nullptr, &tv) > 0) {
        int err = 0;
        socklen_t el = sizeof(err);
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &el);
        ok = (err == 0);
    }
    close(fd);
    return ok;
}

std::string VoiceInputEngine::healthCheckJson(bool deep) {
    auto esc = [](const std::string &x) { return flutterJsonEscape(x); };
    std::ostringstream j;
    j << "{";
    j << "\"engine\":\"" << AsrEngineKindToString(config_.asrEngine.value())
      << "\"";

    // —— Sherpa（双架构：joiner 存在 = zipformer，否则 paraformer）——
    std::string mdir = resolveSherpaModelDir(&config_);
    auto fileOk = [&mdir](const char *f) {
        return access((mdir + "/" + f).c_str(), R_OK) == 0;
    };
    bool isZipformer =
        !findModelFile(mdir, "joiner", false).empty();
    bool sEnc, sDec, sTok = fileOk("tokens.txt");
    std::string arch;
    if (isZipformer) {
        arch = "zipformer";
        sEnc = !findModelFile(mdir, "encoder", false).empty();
        sDec = !findModelFile(mdir, "decoder", false).empty();
    } else {
        arch = "paraformer";
        sEnc = fileOk("encoder.int8.onnx");
        sDec = fileOk("decoder.int8.onnx");
    }
    j << ",\"sherpa\":{\"model_dir\":\"" << esc(mdir) << "\",\"arch\":\""
      << arch << "\",\"ok\":" << ((sEnc && sDec && sTok) ? "true" : "false");
    if (deep && sEnc && sDec && sTok && state_ == State::Idle) {
        // 试加载（~1s，会话中跳过）
        SherpaOnnxOnlineRecognizerConfig c = {};
        std::string tok = mdir + "/tokens.txt";
        c.feat_config.sample_rate = 16000;
        c.feat_config.feature_dim = 80;
        // 路径字符串必须存活到 Create 调用结束（c_str() 悬垂=config 错误）
        std::string enc = findModelFile(mdir, "encoder", !isZipformer);
        std::string dec = findModelFile(mdir, "decoder", !isZipformer);
        std::string jn = findModelFile(mdir, "joiner", false);
        if (isZipformer) {
            c.model_config.transducer.encoder = enc.c_str();
            c.model_config.transducer.decoder = dec.c_str();
            c.model_config.transducer.joiner = jn.c_str();
        } else {
            c.model_config.paraformer.encoder = enc.c_str();
            c.model_config.paraformer.decoder = dec.c_str();
        }
        c.model_config.tokens = tok.c_str();
        c.model_config.num_threads = config_.sherpaNumThreads.value();
        c.model_config.provider = "cpu";
        c.decoding_method = "greedy_search";
        auto t0 = std::chrono::steady_clock::now();
        auto *rec = SherpaOnnxCreateOnlineRecognizer(&c);
        auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                      std::chrono::steady_clock::now() - t0)
                      .count();
        if (rec) {
            SherpaOnnxDestroyOnlineRecognizer(
                const_cast<SherpaOnnxOnlineRecognizer *>(rec));
            j << ",\"deep\":{\"ok\":true,\"load_ms\":" << ms << "}";
        } else {
            j << ",\"deep\":{\"ok\":false}";
        }
    }
    j << "}";

    // —— FunASR 服务 ——
    std::string fhost;
    int fport = 0;
    {
        auto url = config_.funasrUrl.value();
        auto pos = url.rfind(':');
        if (pos != std::string::npos) {
            fhost = url.substr(0, pos);
            fhost = fhost.substr(fhost.find("//") + 2);
            fport = atoi(url.c_str() + pos + 1);
        }
    }
    long rss = 0;
    pid_t fpid = findFunasrPid(fport, &rss);
    j << ",\"funasr\":{\"running\":" << (fpid > 0 ? "true" : "false");
    if (fpid > 0) {
        j << ",\"pid\":" << fpid << ",\"rss_mb\":" << (rss / 1024);
    }
    if (!fhost.empty() && fport > 0) {
        j << ",\"port_listening\":"
          << (portListening(fhost, fport) ? "true" : "false");
    }
    j << "}";

    // —— FunASR Local（GGUF）——
    const std::string &gdir = config_.funasrLocalModelDir.value();
    j << ",\"funasr_local\":{\"dir\":\"" << esc(gdir)
      << "\",\"exists\":" << (access(gdir.c_str(), F_OK) == 0 ? "true" : "false")
      << "}";

    // —— SenseVoice（Sherpa 松手重识别，可选）——
    const std::string &svDir = config_.senseVoiceDir.value();
    bool svOk = !svDir.empty() &&
                access((svDir + "/model.int8.onnx").c_str(), R_OK) == 0 &&
                access((svDir + "/tokens.txt").c_str(), R_OK) == 0;
    j << ",\"sensevoice\":{\"dir\":\"" << esc(svDir) << "\",\"ok\":"
      << (svOk ? "true" : "false") << ",\"enabled\":"
      << (svDir.empty() ? "false" : "true") << "}";

    // —— 建议 ——
    std::string advice;
    switch (config_.asrEngine.value()) {
    case AsrEngineKind::Sherpa:
        if (!sEnc || !sDec || !sTok) {
            advice = "模型缺失：scripts/fetch-sherpa-models.sh 下载";
        } else if (!svDir.empty() && !svOk) {
            advice = "SenseVoice 目录配置了但模型缺失："
                     "fetch-sherpa-models.sh --model sensevoice，"
                     "或清空 SenseVoiceDir 关闭";
        } else {
            advice = "就绪";
        }
        break;
    case AsrEngineKind::FunASR:
        if (fpid <= 0) {
            advice = "服务未运行" +
                     std::string(config_.funasrAutoStart.value()
                                     ? "（AutoStart 会在下次触发时拉起）"
                                     : "：funasr-serve.sh start");
        } else {
            advice = "服务运行中 pid=" + std::to_string(fpid);
        }
        break;
    case AsrEngineKind::FunASRLocal:
        advice = access(gdir.c_str(), F_OK) == 0 ? "就绪" : "GGUF 目录缺失";
        break;
    default:
        advice = "调试引擎";
    }
    j << ",\"advice\":\"" << esc(advice) << "\"}";
    return j.str();
}

void VoiceInputEngine::onEngineChanged(AsrEngineKind next) {
    if (next == lastEngine_) {
        return;
    }
    lastEngine_ = next;
    const std::string &cmd = config_.funasrServerCmd.value();
    std::string host;
    int port = 0;
    {
        auto url = config_.funasrUrl.value();
        auto pos = url.rfind(':');
        if (pos != std::string::npos) {
            host = url.substr(0, pos);
            host = host.substr(host.find("//") + 2);
            port = atoi(url.c_str() + pos + 1);
        }
    }
    if (next != AsrEngineKind::FunASR && !cmd.empty() &&
        findFunasrPid(port, nullptr) > 0) {
        // 切离 FunASR：服务在跑就停（释放 3.7G RAM + 5.1G VRAM）
        runServerScript(cmd, "stop");
        FCITX_INFO() << "VoiceInput: 引擎切换→" << AsrEngineKindToString(next)
                     << "，已停止 funasr 服务";
    } else if (next == AsrEngineKind::FunASR &&
               config_.funasrAutoStart.value() && !cmd.empty() &&
               findFunasrPid(port, nullptr) <= 0) {
        // 切回 FunASR 且 AutoStart：拉起（模型加载 15-60s）
        runServerScript(cmd, "start");
        FCITX_INFO() << "VoiceInput: 引擎切换→FunASR（AutoStart），拉起服务";
    }
}

void VoiceInputEngine::runServerScript(const std::string &cmd,
                                        const std::string &action) {
    if (pid_t pid = fork(); pid == 0) {
        setsid();
        int devnull = open("/dev/null", O_WRONLY);
        if (devnull >= 0) {
            dup2(devnull, 1);
            dup2(devnull, 2);
        }
        char *const argv[] = {const_cast<char *>(cmd.c_str()),
                              const_cast<char *>(action.c_str()), nullptr};
        execv(cmd.c_str(), argv);
        _exit(127);
    }
}

// Flutter 资产发现：env 覆盖 → 用户级（~/.local/share）→ 系统包安装路径
static bool findFlutterAssets(std::string *assetsDir, std::string *icuPath) {
    if (const char *env = getenv("VOICEINPUT_FLUTTER_DIR"); env && *env) {
        *assetsDir = std::string(env) + "/flutter_assets";
        *icuPath = std::string(env) + "/icudtl.dat";
        return true;
    }
    std::vector<std::string> candidates;
    if (const char *xdg = getenv("XDG_DATA_HOME"); xdg && *xdg) {
        candidates.push_back(std::string(xdg) + "/fcitx5-voiceinput/flutter");
    } else if (const char *home = getenv("HOME"); home && *home) {
        candidates.push_back(std::string(home) +
                             "/.local/share/fcitx5-voiceinput/flutter");
    }
    candidates.push_back("/usr/share/fcitx5-voiceinput/flutter");
    candidates.push_back("/usr/local/share/fcitx5-voiceinput/flutter");
    for (const auto &dir : candidates) {
        std::string assets = dir + "/flutter_assets";
        std::string icu = dir + "/icudtl.dat";
        if (access(assets.c_str(), F_OK) == 0 && access(icu.c_str(), R_OK) == 0) {
            *assetsDir = assets;
            *icuPath = icu;
            return true;
        }
    }
    return false;
}

VoiceInputEngine::VoiceInputEngine(Instance *instance)
    : instance_(instance) {
    // 配置：~/.config/fcitx5/conf/voiceinput.config（不存在则用默认值）
    readAsIni(config_, "conf/voiceinput.config");
    reloadConfig();

    popup_ = std::make_unique<VoicePopup>(instance_);
    popup_->setPositionPolicy(config_.positionMode.value(),
                              config_.positionFallbackApps.value());
    flutter_ = std::make_unique<FlutterEngineHost>(&instance_->eventLoop());

    // 帧：引擎软渲输出（主线程）→ popup wl_shm
    flutter_->setFrameCallback([this](const uint8_t *bgra, int w, int h) {
        if (popup_) {
            popup_->pushFrameBGRA(bgra, w, h);
        }
    });
    // 指针：popup 表面局部坐标 → FlutterPointerEvent（hover/点击 Dart 命中）
    popup_->setPointerSink([this](VoicePopup::PointerEvent kind, int x, int y) {
        using PK = FlutterEngineHost::PointerKind;
        static constexpr PK map[] = {
            PK::Enter, PK::Leave, PK::Motion, PK::Press, PK::Release,
        };
        if (flutter_) {
            flutter_->onPointer(map[static_cast<int>(kind)],
                                static_cast<double>(x), static_cast<double>(y));
        }
    });
    // W3 尺寸/scale 统筹：Dart 逻辑尺寸 → popup 物理池+viewport +
    // 引擎 metrics（pixelRatio=真实 scale → 渲染物理帧，无拉伸模糊）
    flutter_->setResizeHandler([this](int w, int h) {
        if (popup_) {
            popup_->setLogicalSize(w, h);
        }
        // metrics 更新 defer 到事件循环下一轮：resize 消息来自引擎平台
        // 回调、scale 来自 wayland dispatch——在这些上下文里同步调
        // SendWindowMetricsEvent 会与引擎内部锁重入死锁（宿主机实测卡死）
        deferredMetrics(w, h);
    });
    // 合成器 scale 变化（跨屏移动/用户改缩放）→ 用当前逻辑尺寸重设 metrics
    popup_->setScaleHandler([this](double) {
        if (popup_ && popup_->logicalWidth() > 0) {
            deferredMetrics(popup_->logicalWidth(), popup_->logicalHeight());
        }
    });
    // Dart → C++：ready/resize 已由引擎处理，selectCandidate/hoverChanged 到这
    flutter_->setMessageHandler(
        [this](const std::string &method, const std::string &args) {
            onFlutterMessage(method, args);
        });

    // 全局触发键拦截（PreInputMethod：rime/pinyin 等引擎之前）——共存核心
    keyWatcher_ = instance_->watchEvent(
        EventType::InputContextKeyEvent, EventWatcherPhase::PreInputMethod,
        [this](Event &event) {
            auto &keyEvent = static_cast<KeyEvent &>(event);
            auto *ic = keyEvent.inputContext();
            if (!ic) {
                return;
            }
            // 活动会话只认会话 IC；其他窗口的按键不掺和
            if (state_ != State::Idle && ic != sessionIcRef_.get()) {
                return;
            }
            const bool trig = isTriggerKey(keyEvent.key());
            const bool handled =
                handleKey(keyEvent.key(), !keyEvent.isRelease(), ic);
            // 模态（录音/结果/候选）：除触发键外全部吞掉——防止击键漏进
            // rime/应用（吞 = 引擎收不到 + 不转发应用）
            const bool modal = state_ == State::Recording ||
                               state_ == State::Result ||
                               state_ == State::Candidates;
            if ((modal || handled) && !trig) {
                keyEvent.filterAndAccept();
                return;
            }
            // 触发键事件永不 filter（包括被状态机消费的）：press 已透传给
            // 应用，release 必须配对，否则应用 xkb 卡在"Ctrl 按下"；
            // lone modifier 的 press+release 对应用是 no-op
        });

    // popup 预热：焦点 IC 变化即预建 popup 并提交透明帧（niri 对 IM
    // popup 的 map 有 ~2s 流水线延迟，等录音才建就看不见卡片了）——
    // 相当于旧 activate() 的 prepare 预热，改为跟随焦点
    focusWatcher_ = instance_->watchEvent(
        EventType::InputContextFocusIn, EventWatcherPhase::PreInputMethod,
        [this](Event &event) {
            auto &iev = static_cast<InputContextEvent &>(event);
            if (state_ == State::Idle && popup_) {
                popup_->prepare(iev.inputContext());
            }
        });

    // 注册测试 D-Bus 服务。addon 加载期 dbus 模块可能未就绪（原来靠
    // activate() 补注册，Module 化后没有 activate）——1s 重试直到挂上
    ensureTestService();
    if (!testService_) {
        dbusRetry_ = instance_->eventLoop().addTimeEvent(
            CLOCK_MONOTONIC, nowUs() + 1000000, 0,
            [this](EventSourceTime *, uint64_t) {
                ensureTestService();
                if (testService_) {
                    dbusRetry_.reset();
                    return false;
                }
                return true; // 未就绪，1s 后再试
            });
    }

    // 预热：加载 5s 后初始化 Flutter 引擎（JIT 冷启动较慢，等触发再拉
    // 就晚了；失败则懒重试——beginRecording 也会调 startFlutterEngine）
    warmupTimer_ = instance_->eventLoop().addTimeEvent(
        CLOCK_MONOTONIC, nowUs() + 5000000, 0, [this](EventSourceTime *, uint64_t) {
            startFlutterEngine();
            // popup 预热兜底（focus 事件可能早已错过）
            if (state_ == State::Idle && popup_) {
                if (auto *ic = instance_->inputContextManager()
                                   .lastFocusedInputContext()) {
                    popup_->prepare(ic);
                }
            }
            return false; // 一次性
        });
    if (warmupTimer_) {
        warmupTimer_->setOneShot();
    }

    FCITX_INFO() << "VoiceInput module loaded (config: mode="
                 << TriggerModeToString(config_.triggerMode.value())
                 << " keys=" << config_.triggerKeys.value().size()
                 << " engine="
                 << AsrEngineKindToString(config_.asrEngine.value())
                 << ")——全局热键模式，与其他输入法共存";
}

VoiceInputEngine::~VoiceInputEngine() {
    // 故意泄漏 VoicePopup：addon unload 后 wayland display 仍会 dispatch
    // 若干轮（fractional scale/output 事件），销毁对象会让回调打进已释放
    // 内存（SIGTERM 退出 SEGV，宿主机实测）。进程退出统一回收
    (void)popup_.release();
}

AddonInstance *VoiceInputEngineFactory::create(AddonManager *manager) {
    return new VoiceInputEngine(manager->instance());
}

void VoiceInputEngine::reloadConfig() {
    readAsIni(config_, "conf/voiceinput.config");
    if (popup_) { // 定位策略热更新（PositionMode/PositionFallbackApps）
        popup_->setPositionPolicy(config_.positionMode.value(),
                                  config_.positionFallbackApps.value());
    }
    uiNotify("config-reloaded");
}

// configtool 保存链路：D-Bus SetConfig → setConfig（基类默认 no-op）。
// 与 classicui 同模式：载入 + 落盘 + 应用
void VoiceInputEngine::setConfig(const RawConfig &config) {
    auto prev = config_.asrEngine.value();
    config_.load(config, true);
    if (safeSaveAsIni(config_, "conf/voiceinput.config")) {
        FCITX_INFO() << "VoiceInput: configtool 保存已落盘";
    }
    if (config_.asrEngine.value() != prev) {
        onEngineChanged(config_.asrEngine.value());
    }
    sendFontToUi(); // 字体热改（UIFont/classicui Font 变化即生效）
    if (popup_) {
        popup_->setPositionPolicy(config_.positionMode.value(),
                                  config_.positionFallbackApps.value());
    }
    uiNotify("config-saved-via-configtool");
}

void VoiceInputEngine::ensureTestService() {
    if (testService_ || !instance_) {
        return;
    }
    auto *dbus = instance_->addonManager().addon("dbus", true);
    if (!dbus) {
        FCITX_WARN() << "dbus module unavailable, test hook disabled";
        return;
    }
    bus_ = dbus->call<IDBusModule::bus>();
    if (!bus_) {
        return;
    }
    testService_ = std::make_unique<TestService>(this);
    bus_->addObjectVTable("/org/fcitx/VoiceInput", "org.fcitx.VoiceInput.Test",
                          *testService_);
    FCITX_INFO() << "VoiceInput test D-Bus service registered";
}

// ---------------------------------------------------------------------------
// Flutter 引擎
// ---------------------------------------------------------------------------

void VoiceInputEngine::startFlutterEngine() {
    if (flutter_->running()) {
        return;
    }
    std::string assets, icu;
    if (!findFlutterAssets(&assets, &icu)) {
        FCITX_WARN() << "VoiceInput: Flutter 资产未找到（"
                        "VOICEINPUT_FLUTTER_DIR 可覆盖；安装包应含 "
                        "/usr/share/fcitx5-voiceinput/flutter）——回退色块模式";
        if (popup_) {
            popup_->setPatternMode(true);
        }
        return;
    }
    if (flutter_->start(assets, icu)) {
        pushUiState(); // 引擎就绪即同步当前状态（Dart 冷启动有个过程）
    }
}

void VoiceInputEngine::pushUiState() {
    if (!flutter_ || !flutter_->running()) {
        return;
    }
    switch (state_) {
    case State::Recording:
        flutter_->sendUpdate(
            "{\"state\":\"recording\",\"partial\":\"" +
            flutterJsonEscape(partial_) + "\",\"elapsed_ms\":" +
            std::to_string((nowUs() - recordStartUs_) / 1000) + "}");
        break;
    case State::Result:
        flutter_->sendUpdate(
            "{\"state\":\"result\",\"final\":\"" +
            flutterJsonEscape(finalText_) + "\",\"timeout_ms\":" +
            std::to_string(config_.popupTimeoutMs.value()) + "}");
        break;
    case State::Candidates: {
        std::string arr;
        for (size_t i = 0; i < candidates_.size(); ++i) {
            if (i) {
                arr += ",";
            }
            arr += "\"" + flutterJsonEscape(candidates_[i]) + "\"";
        }
        // hover：鼠标悬停优先，否则键盘方向键选择行
        const int hover = uiHoverRow_ >= 0 ? uiHoverRow_ : keyboardRow_;
        flutter_->sendUpdate(
            "{\"state\":\"candidates\",\"final\":\"" +
            flutterJsonEscape(finalText_) + "\",\"candidates\":[" + arr +
            "],\"hover\":" + std::to_string(hover) + "}");
        break;
    }
    case State::Idle:
    case State::Pressing:
        flutter_->sendUpdate("{\"state\":\"idle\"}");
        break;
    }
}

// —— UI 字体解析（W4）：UIFont 配置 > classicui 的 Font > 内置 NotoSansSC ——
// 返回 {"path","family","size"}；path 空 = 用内置兜底
std::string VoiceInputEngine::resolveUiFont() {
    std::string pango = config_.uiFont.value();
    if (pango.empty()) {
        // 跟随 classicui：读其配置文件的 Font（如 "MiSans VF 12"）
        auto f = StandardPath::global().open(StandardPath::Type::PkgConfig,
                                              "conf/classicui.conf",
                                              O_RDONLY);
        if (f.fd() >= 0) {
            FILE *fp = fdopen(dup(f.fd()), "r");
            char line[512];
            std::string fontLine;
            while (fgets(line, sizeof(line), fp)) {
                if (strncmp(line, "Font=", 5) == 0) {
                    fontLine = line + 5;
                    break;
                }
            }
            fclose(fp);
            // 去引号/换行
            auto clean = [](std::string x) {
                while (!x.empty() && (x.back() == '\n' || x.back() == '"' ||
                                      x.back() == '\r' || x.back() == ' ')) {
                    x.pop_back();
                }
                size_t b = x.find_first_not_of(" \"");
                return b == std::string::npos ? "" : x.substr(b);
            };
            pango = clean(fontLine);
        }
    }
    if (pango.empty()) {
        return "{}";
    }
    // Pango 串："Family1,Family2 12"——末尾数字为 size，其余为 family 列表
    int size = 12;
    std::string families = pango;
    auto pos = pango.find_last_of(' ');
    if (pos != std::string::npos) {
        int v = atoi(pango.c_str() + pos + 1);
        if (v > 4 && v < 100) {
            size = v;
            families = pango.substr(0, pos);
        }
    }
    // fontconfig 匹配 family → 字体文件
    std::string path;
    FcConfig *fc = FcInitLoadConfigAndFonts();
    if (fc) {
        FcPattern *pat = FcPatternBuild(nullptr, FC_FAMILY, FcTypeString,
                                        (FcChar8 *)families.c_str(), nullptr);
        FcConfigSubstitute(fc, pat, FcMatchPattern);
        FcDefaultSubstitute(pat);
        FcResult res = FcResultNoMatch;
        FcPattern *match = FcFontMatch(fc, pat, &res);
        if (match && res == FcResultMatch) {
            FcChar8 *file = nullptr;
            if (FcPatternGetString(match, FC_FILE, 0, &file) == FcResultMatch &&
                file) {
                path = (const char *)file;
            }
            FcPatternDestroy(match);
        }
        FcPatternDestroy(pat);
        FcConfigDestroy(fc);
    }
    std::ostringstream j;
    j << "{\"path\":\"" << flutterJsonEscape(path)
      << "\",\"family\":\"" << flutterJsonEscape(families)
      << "\",\"size\":" << size << "}";
    return j.str();
}

// W4：字体跟随下发（classicui Font → fontconfig 文件 → Dart FontLoader）。
// 解析必须放后台线程：fontconfig 全局锁与 classicui/pango 的字体线程
// 互等——主循环同步调 FcInitLoadConfigAndFonts 会死锁（宿主机实测主线程
// 与 [pango] fontcon 双双 futex 等待，键盘输入全冻结）
void VoiceInputEngine::sendFontToUi() {
    if (!flutter_ || !flutter_->running() || fontResolving_) {
        return;
    }
    fontResolving_ = true;
    // 结果经 pipe 唤醒主循环下发（EventSourceIO）
    if (fontPipe_[1] < 0 && pipe(fontPipe_) != 0) {
        fontResolving_ = false;
        return;
    }
    // 读端非阻塞：IO 回调里的排空循环靠 EAGAIN 返回，否则第二次 read
    // 会把主循环卡死在管道上（容器实测 State 全超时）
    int fl = fcntl(fontPipe_[0], F_GETFL);
    fcntl(fontPipe_[0], F_SETFL, fl | O_NONBLOCK);
    fontIo_ = instance_->eventLoop().addIOEvent(
        fontPipe_[0], IOEventFlag::In,
        [this](EventSourceIO *, int fd, IOEventFlags) {
            char buf[64];
            while (read(fd, buf, sizeof(buf)) > 0) {
            }
            fontIo_.reset();
            std::string json;
            {
                std::lock_guard<std::mutex> lock(fontMutex_);
                json = std::move(fontJson_);
            }
            fontResolving_ = false;
            if (json.length() > 4) {
                flutter_->sendUpdate("{\"state\":\"font\"," + json.substr(1));
                FCITX_INFO() << "VoiceInput: UI 字体 → " << json;
            }
            return true;
        });
    std::thread([this] {
        std::string json = resolveUiFont();
        {
            std::lock_guard<std::mutex> lock(fontMutex_);
            fontJson_ = std::move(json);
        }
        char one = 1;
        (void)!write(fontPipe_[1], &one, 1);
    }).detach();
}

// metrics 更新统一 defer（防 dispatch/平台回调上下文重入引擎锁）
void VoiceInputEngine::deferredMetrics(int w, int h) {
    pendingMW_ = w;
    pendingMH_ = h;
    metricsTimer_ = instance_->eventLoop().addTimeEvent(
        CLOCK_MONOTONIC, nowUs() + 1000, 0, [this](EventSourceTime *, uint64_t) {
            double sc = popup_ ? popup_->scale() : 1.0;
            if (flutter_ && flutter_->running()) {
                // FlutterWindowMetricsEvent 的 width/height 是物理像素
                //（引擎不乘 ratio）——传逻辑会让 Dart 布局被压成 1/sc
                flutter_->updateMetrics(
                    static_cast<int>(pendingMW_ * sc + 0.5),
                    static_cast<int>(pendingMH_ * sc + 0.5), sc);
            }
            return false;
        });
    if (metricsTimer_) {
        metricsTimer_->setOneShot();
    }
}

void VoiceInputEngine::onFlutterMessage(const std::string &method,
                                        const std::string &args) {
    // {"index":N} / {"row":N}——极简字段提取（协议自约定）
    auto numOf = [](const std::string &s, const char *key) -> int {
        auto pos = s.find(std::string("\"") + key + "\":");
        if (pos == std::string::npos) {
            return -1;
        }
        return atoi(s.c_str() + pos + strlen(key) + 3);
    };
    if (method == "selectCandidate") {
        int idx = numOf(args, "index");
        if (state_ == State::Candidates && idx >= 0) {
            uiNotify("mouse-click-row", std::to_string(idx));
            commitCandidate(static_cast<size_t>(idx),
                            sessionIcRef_.get());
        }
    } else if (method == "hoverChanged") {
        uiHoverRow_ = numOf(args, "row");
    } else if (method == "ready") {
        FCITX_INFO() << "VoiceInput: Flutter UI ready";
        pushUiState();
        sendFontToUi();
    }
}

// ---------------------------------------------------------------------------
// 状态机
// ---------------------------------------------------------------------------

bool VoiceInputEngine::isTriggerKey(const Key &key) const {
    const auto &list = config_.triggerKeys.value();
    // 标准匹配（非修饰键路径）
    if (key.keyListIndex(list) >= 0) {
        return true;
    }
    // 纯修饰键特例：真实键盘事件自带自身修饰 state 且带 keycode
    //（Key::check 的 keycode 分支要求全等，裸 Key("Control_R") 永远不匹配
    //——宿主机实测按住 10s 无反应的根因；容器测试用 SimulateKey 构造的
    //干净键从未暴露）。fcitx 惯例配置写 Control+Control_R，但裸写也要认
    if (key.isModifier()) {
        for (const auto &k : list) {
            if (k.sym() == key.sym()) {
                return true;
            }
        }
    }
    return false;
}

bool VoiceInputEngine::handleKey(const Key &key, bool pressed,
                                 InputContext *ic) {
    // —— 候选状态：数字/Enter/空格/Esc/方向键 ——
    if (state_ == State::Candidates && pressed) {
        if (key.check(FcitxKey_Return) || key.check(FcitxKey_KP_Enter) ||
            key.check(FcitxKey_space)) {
            commitCandidate(static_cast<size_t>(keyboardRow_), ic);
            return true;
        }
        if (key.check(FcitxKey_Escape)) {
            uiNotify("cancelled");
            enterIdle();
            return true;
        }
        static const KeySym digits[] = {
            FcitxKey_1, FcitxKey_2, FcitxKey_3, FcitxKey_4, FcitxKey_5,
            FcitxKey_6, FcitxKey_7, FcitxKey_8, FcitxKey_9,
        };
        for (size_t i = 0; i < 9 && i < candidates_.size(); ++i) {
            if (key.check(digits[i])) {
                commitCandidate(i, ic);
                return true;
            }
        }
        const size_t n = candidates_.size();
        if (n > 0) {
            if (key.check(FcitxKey_Down) || key.check(FcitxKey_Right)) {
                keyboardRow_ = static_cast<int>((keyboardRow_ + 1) % n);
                pushUiState();
                return true;
            }
            if (key.check(FcitxKey_Up) || key.check(FcitxKey_Left)) {
                keyboardRow_ =
                    static_cast<int>((keyboardRow_ + n - 1) % n);
                pushUiState();
                return true;
            }
        }
    }

    const bool trigger = isTriggerKey(key);

    switch (state_) {
    case State::Idle:
        if (trigger && pressed) {
            if (!ic) {
                return false; // 无 IC（TestService 无焦点等）：不启动会话
            }
            sessionIcRef_ = ic->watch();
            state_ = State::Pressing;
            startThresholdTimer();
            uiNotify("pressing");
            return true; // 状态机已处理（watcher 决定是否吞——触发键不吞）
        }
        break;

    case State::Pressing:
        if (trigger && !pressed) {
            // 未到阈值松开：回 Idle（press 已透传应用，release 配对透传）
            thresholdTimer_.reset();
            enterIdle();
            return true;
        }
        if (!trigger) {
            // 组合键场景（Ctrl+S）：任何其他键到达即取消候选，全部透传
            thresholdTimer_.reset();
            enterIdle();
            return false;
        }
        break;

    case State::Recording:
        if (pressed && key.check(FcitxKey_Escape)) {
            // 录音中取消：中止会话，不产生任何提交
            if (asr_) {
                asr_->cancel();
            }
            uiNotify("cancelled");
            enterIdle();
            return true;
        }
        if (config_.triggerMode.value() == TriggerMode::HoldRelease) {
            if (trigger && !pressed) {
                finishRecording();
                return true;
            }
        } else { // Toggle
            if (!pressed && trigger) {
                toggleReleased_ = true; // 起始按住的键松开，不停
                return true;
            }
            if (pressed && trigger && toggleReleased_) {
                finishRecording(); // 再次按下 → 结束
                return true;
            }
        }
        break;

    case State::Result:
        if (trigger && pressed) {
            // 结果展示期间再按触发键：跳过等待立即上屏
            resultTimer_.reset();
            if (auto *ic = sessionIcRef_.get()) {
                ic->commitString(finalText_);
            }
            uiNotify("committed", finalText_);
            enterIdle();
            return true;
        }
        break;

    case State::Candidates:
        if (trigger && pressed) {
            uiNotify("cancelled");
            enterIdle();
            return true;
        }
        break;
    }
    return false; // 其余按键透传给应用
}

void VoiceInputEngine::startThresholdTimer() {
    thresholdTimer_.reset();
    thresholdTimer_ = instance_->eventLoop().addTimeEvent(
        CLOCK_MONOTONIC, nowUs() + config_.triggerThresholdMs.value() * 1000, 0,
        [this](EventSourceTime *, uint64_t) {
            if (state_ == State::Pressing) {
                if (auto *ic = sessionIcRef_.get()) {
                    beginRecording(ic);
                } else {
                    enterIdle(); // hold 期间 IC 已销毁
                }
            }
            return true;
        });
    if (thresholdTimer_) {
        thresholdTimer_->setOneShot();
    }
}

// 按当前配置创建 ASR 引擎（会话级：配置热改后下一会话即生效）
static std::unique_ptr<AsrEngine> makeAsrEngine(const VoiceInputConfig &cfg) {
    switch (cfg.asrEngine.value()) {
    case AsrEngineKind::FunASR:
        return std::make_unique<FunAsrWsEngine>();
    case AsrEngineKind::FunASRLocal:
        return std::make_unique<FunAsrLocalEngine>();
    case AsrEngineKind::Sherpa:
        return std::make_unique<SherpaOnnxEngine>();
    case AsrEngineKind::Dummy:
    default:
        return std::make_unique<DummyAsrEngine>();
    }
}

void VoiceInputEngine::beginRecording(InputContext *ic) {
    if (!ic) {
        enterIdle();
        return;
    }
    state_ = State::Recording;
    toggleReleased_ = false;
    recordStartUs_ = nowUs();
    // 引擎随会话创建（旧引擎若在跑先取消）
    if (asr_) {
        asr_->cancel();
    }
    asr_ = makeAsrEngine(config_);
    if (popup_) {
        popup_->show(ic);
    }
    startFlutterEngine(); // 懒兜底（预热失败/未到 5s 就触发）
    if (flutter_->running()) {
        pushUiState();
    } else if (popup_) {
        // 引擎不可用：回退色块（popup 直接绘制）
        popup_->setPatternMode(true);
        popup_->show(ic);
    }
    partial_.clear();
    finalText_.clear();
    candidates_.clear();
    uiNotify("recording-start");
    if (!asr_) {
        return;
    }
    AsrEngine::Callbacks cbs;
    cbs.onPartial = [this](const std::string &text) { onAsrPartial(text); };
    cbs.onFinish = [this](const std::string &text) { onAsrFinish(text); };
    asr_->start(&instance_->eventLoop(), &config_, std::move(cbs));
}

void VoiceInputEngine::finishRecording() {
    uiNotify("recording-stop");
    // 尾音宽限：parec/PulseAudio 链路还有 ~200-300ms 已采音频在路上，
    // 且解码需要时间追平——立刻 stop 会截掉松开前的内容（漏字）。
    // 期间保持 Recording（partial 继续推进），350ms 后取 final
    tailTimer_ = instance_->eventLoop().addTimeEvent(
        CLOCK_MONOTONIC, nowUs() + 350000, 0,
        [this](EventSourceTime *, uint64_t) {
            if (state_ == State::Recording && asr_) {
                asr_->stop(); // 触发 onFinish（stop 内含管道 drain）
            } else if (state_ == State::Recording) {
                onAsrFinish(partial_);
            }
            return false;
        });
    if (tailTimer_) {
        tailTimer_->setOneShot();
    }
}

void VoiceInputEngine::onAsrPartial(const std::string &text) {
    if (state_ != State::Recording) {
        return;
    }
    partial_ = text;
    pushUiState();
    uiNotify("partial", text);
}

void VoiceInputEngine::onAsrFinish(const std::string &text) {
    if (state_ != State::Recording) {
        return;
    }
    finalText_ = text;
    if (config_.llmEnabled.value()) {
        // Dummy 阶段：候选 = [润色版, 原始版]（润色=保尾标点，真实 LLM 后替换）
        candidates_ = {polish(finalText_), finalText_};
        state_ = State::Candidates;
        keyboardRow_ = 0;
        pushUiState();
        uiNotify("candidates", joinCandidates());
    } else {
        state_ = State::Result;
        pushUiState();
        uiNotify("result", finalText_);
        startResultTimer();
    }
}

void VoiceInputEngine::startResultTimer() {
    resultTimer_.reset();
    resultTimer_ = instance_->eventLoop().addTimeEvent(
        CLOCK_MONOTONIC, nowUs() + config_.popupTimeoutMs.value() * 1000, 0,
        [this](EventSourceTime *, uint64_t) {
            if (auto *ic = sessionIcRef_.get();
                state_ == State::Result && ic) {
                ic->commitString(finalText_);
                uiNotify("committed", finalText_);
            }
            enterIdle();
            return true;
        });
    if (resultTimer_) {
        resultTimer_->setOneShot();
    }
}

void VoiceInputEngine::commitCandidate(size_t index, InputContext *ic) {
    if (index >= candidates_.size()) {
        return;
    }
    auto text = candidates_[index];
    if (ic) {
        ic->commitString(text);
    } else if (auto *ic = sessionIcRef_.get()) {
        ic->commitString(text);
    }
    uiNotify("committed", text);
    enterIdle();
}

void VoiceInputEngine::enterIdle() {
    if (popup_) {
        popup_->hide();
    }
    if (flutter_ && flutter_->running()) {
        flutter_->sendUpdate("{\"state\":\"idle\"}");
    }
    state_ = State::Idle;
    thresholdTimer_.reset();
    tailTimer_.reset();
    resultTimer_.reset();
    if (asr_) {
        asr_->stop();
    }
    candidates_.clear();
    partial_.clear();
    finalText_.clear();
    toggleReleased_ = false;
    uiNotify("idle");
}

std::string VoiceInputEngine::stateName() const {
    switch (state_) {
    case State::Idle: return "idle";
    case State::Pressing: return "pressing";
    case State::Recording: return "recording";
    case State::Result: return "result";
    case State::Candidates: return "candidates";
    }
    return "?";
}

// —— Dummy 润色：句末无标点则补句号（真实 LLM 接入后替换）——
std::string VoiceInputEngine::polish(const std::string &text) {
    if (text.empty()) {
        return text;
    }
    // 只看最后一个字符是否 ASCII/全角标点结尾
    static const std::string endings = "。！？.!?,，;；";
    if (endings.find(text.back()) == std::string::npos) {
        return text + "。";
    }
    return text;
}

std::string VoiceInputEngine::joinCandidates() const {
    std::string out;
    for (size_t i = 0; i < candidates_.size(); ++i) {
        if (i) out += " | ";
        out += std::to_string(i + 1) + "." + candidates_[i];
    }
    return out;
}

void VoiceInputEngine::uiNotify(const std::string &what,
                                const std::string &detail) {
    FCITX_INFO() << "[ui] " << what << (detail.empty() ? "" : ": " + detail);
}

// ---------------------------------------------------------------------------
// 测试钩子
// ---------------------------------------------------------------------------

std::string TestService::Trigger(std::string text) {
    auto *ic = engine_->instance()->inputContextManager()
                   .lastFocusedInputContext();
    if (!ic) {
        return "error: no focused input context";
    }
    ic->commitString(text);
    return "ok: " + text;
}

std::string TestService::SimulateKey(std::string key, bool pressed) {
    engine_->handleKey(Key(key), pressed,
                       engine_->instance()->inputContextManager()
                           .lastFocusedInputContext());
    return "ok: " + key + (pressed ? " down" : " up") + " → " +
           engine_->stateName();
}

// 走真实事件管线：验证 PreInputMethod watcher 的拦截/透传语义。
// postEvent 不会把未消费的合成键转发回客户端——未 filter 时补
// forwardKey，等价于真实按键（waylandim 抓到→引擎不管→回传应用）
std::string TestService::InjectKey(std::string key, bool pressed) {
    auto *ic =
        engine_->instance()->inputContextManager().lastFocusedInputContext();
    if (!ic) {
        return "error: no focused input context";
    }
    KeyEvent ev(ic, Key(key), !pressed);
    engine_->instance()->postEvent(ev);
    if (!ev.filtered()) {
        ic->forwardKey(Key(key), !pressed);
    }
    return "ok: " + key + (pressed ? " down" : " up") + " → " +
           engine_->stateName() +
           (ev.filtered() ? ", filtered=yes" : ", filtered=no");
}

std::string TestService::State() { return engine_->stateName(); }

// 模型部署健康检查：入参 "deep" 时含 sherpa 试加载（~1s）
std::string TestService::HealthCheck(std::string mode) {
    return engine_->healthCheckJson(mode == "deep");
}

// 编译期版本回读：容器/宿主断言加载的二进制与包一致（防"陈旧 dist/
// ~/.local 不生效"类问题——宿主机实测踩过）
std::string TestService::Version() { return VOICEINPUT_VERSION_STRING; }

std::vector<std::string> TestService::Candidates() {
    return engine_->candidates();
}

} // namespace fcitx

FCITX_ADDON_FACTORY(fcitx::VoiceInputEngineFactory)
