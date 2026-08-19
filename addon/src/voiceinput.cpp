#include "voiceinput.h"
#include "flutter_engine.h"
#include "popup_surface.h"
#include "funasr_local_engine.h"
#include "sherpa_engine.h"
#include "funasr_ws_engine.h"

#include <fcitx-config/iniparser.h>
#include <fcitx-utils/keysym.h>
#include <fcitx-utils/log.h>
#include <fcitx/addonmanager.h>
#include <fcitx/inputcontextmanager.h>

#include <dbus_public.h>

#include <unistd.h>

namespace fcitx {

static uint64_t nowUs() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<uint64_t>(ts.tv_sec) * 1000000 + ts.tv_nsec / 1000;
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

VoiceInputEngine::~VoiceInputEngine() = default;

AddonInstance *VoiceInputEngineFactory::create(AddonManager *manager) {
    return new VoiceInputEngine(manager->instance());
}

void VoiceInputEngine::reloadConfig() {
    readAsIni(config_, "conf/voiceinput.config");
    uiNotify("config-reloaded");
}

// configtool 保存链路：D-Bus SetConfig → setConfig（基类默认 no-op）。
// 与 classicui 同模式：载入 + 落盘 + 应用
void VoiceInputEngine::setConfig(const RawConfig &config) {
    config_.load(config, true);
    if (safeSaveAsIni(config_, "conf/voiceinput.config")) {
        FCITX_INFO() << "VoiceInput: configtool 保存已落盘";
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
    if (asr_) {
        asr_->stop(); // 触发 onFinish
    } else {
        onAsrFinish(partial_);
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

// 编译期版本回读：容器/宿主断言加载的二进制与包一致（防"陈旧 dist/
// ~/.local 不生效"类问题——宿主机实测踩过）
std::string TestService::Version() { return VOICEINPUT_VERSION_STRING; }

std::vector<std::string> TestService::Candidates() {
    return engine_->candidates();
}

} // namespace fcitx

FCITX_ADDON_FACTORY(fcitx::VoiceInputEngineFactory)
