#include "ui_addon.h"

#include "flutter_engine.h"
#include "popup_surface.h"

#include <fcitx-utils/log.h>
#include <fcitx/addonmanager.h>
#include <fcitx/inputcontextmanager.h>
#include <fcitx/inputpanel.h>

#include <fcitx-config/iniparser.h>
#include <fcitx-config/rawconfig.h>
// Arch 的 Fcitx5ModuleNotificationItem config 将 include 根指向叶子目录
#include <notificationitem_public.h>
#include <fcitx-utils/standardpath.h>

#include <time.h>
#include <unistd.h>

#include <dlfcn.h>

#include <fstream>
#include <iterator>

#include <chrono>
#include <cstdlib>
#include <cstring>

#include "json_util.h"
#include "proto_line.h"

namespace fcitx {

static uint64_t nowUs() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<uint64_t>(ts.tv_sec) * 1000000 + ts.tv_nsec / 1000;
}

// Flutter 资产发现：env 覆盖 → 系统包安装路径 → 用户级（~/.local/share）。
// 系统包必须优先：~/.local 排前面时，早期手动部署的残留副本会永久遮蔽
// 包管理器的新安装（加载了旧副本却无从察觉）。~/.local 保留给
// tarball/手动安装（无系统包时兜底）
static bool findFlutterAssets(std::string *assetsDir, std::string *icuPath) {
    // 旧环境变量（voiceinput 时代）仍认
    const char *env = getenv("AIINPUT_FLUTTER_DIR");
    if (!env || !*env) {
        env = getenv("VOICEINPUT_FLUTTER_DIR");
    }
    if (env && *env) {
        *assetsDir = std::string(env) + "/flutter_assets";
        *icuPath = std::string(env) + "/icudtl.dat";
        return true;
    }
    std::vector<std::string> candidates;
    candidates.push_back("/usr/share/fcitx5-aiinput/flutter");
    candidates.push_back("/usr/local/share/fcitx5-aiinput/flutter");
    // 旧包路径兜底（新旧包短暂共存/卸载残留场景）
    candidates.push_back("/usr/share/fcitx5-voiceinput/flutter");
    if (const char *xdg = getenv("XDG_DATA_HOME"); xdg && *xdg) {
        candidates.push_back(std::string(xdg) + "/fcitx5-aiinput/flutter");
    } else if (const char *home = getenv("HOME"); home && *home) {
        candidates.push_back(std::string(home) +
                             "/.local/share/fcitx5-aiinput/flutter");
    }
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

AiInputUi::AiInputUi(Instance *instance) : instance_(instance) {
    // 配置一次读全（引擎独占写、本 addon 只读；ini 默认值不落文件，
    // 裸读自备兜底）
    RawConfig raw;
    readAsIni(raw, "conf/aiinput.config");
    if (const auto *fc = raw.valueByPath("FlutterCard")) {
        flutterCard_ = !(*fc == "False" || *fc == "false");
    }

    // popup_ 恒建：text_input_rectangle 只发给 IM popup surface——它是
    // caret/探针/跟随的矩形数据源，FlutterCard=False 时以透明表面存在
    //（prepare 首帧，不画内容），只砍 Flutter 引擎与帧上屏
    popup_ = std::make_unique<VoicePopup>(instance_);
    popup_->setModeSwitchHandler([this]() {
        // surface 切换（结算回退）或挂起解除（矩形到达）：新 surface
        // 需要重推一帧——会话状态在引擎侧，经 uiCommand("ready") 让引擎
        // 重推（ready 分支 = 状态推送 + 字体下发）
        if (auto *engine = this->engine()) {
            engine->call<IAiInputEngine::uiCommand>("ready", "{}");
        }
    });

    if (flutterCard_) {
        flutter_ = std::make_unique<FlutterEngineHost>(&instance_->eventLoop());

        // 帧：引擎软渲输出（主线程）→ popup wl_shm
        flutter_->setFrameCallback([this](const uint8_t *bgra, int w, int h) {
            if (popup_) {
                popup_->pushFrameBGRA(bgra, w, h);
            }
        });
        // 指针：popup 表面局部坐标 → FlutterPointerEvent（hover/点击 Dart 命中）
        popup_->setPointerSink(
            [this](VoicePopup::PointerEvent kind, int x, int y) {
                using PK = FlutterEngineHost::PointerKind;
                static constexpr PK map[] = {
                    PK::Enter, PK::Leave, PK::Motion, PK::Press, PK::Release,
                };
                if (flutter_) {
                    flutter_->onPointer(map[static_cast<int>(kind)],
                                        static_cast<double>(x),
                                        static_cast<double>(y));
                }
                // relay 指针回传：卡片宿主把事件合成 Qt 鼠标进 QML 场景，
                // 候选 hover/点击选择经既有 select/hover 回流（坐标 =
                // 表面逻辑坐标，输出 scale=1 下与帧像素 1:1）
                if (socketUi_) {
                    static constexpr const char *kinds[] = {
                        "enter", "leave", "motion", "press", "release",
                    };
                    socketUi_->sendEnvelope(
                        "panel/pointer",
                        std::string("{\"kind\":\"") +
                            kinds[static_cast<int>(kind)] +
                            "\",\"x\":" + std::to_string(x) +
                            ",\"y\":" + std::to_string(y) + "}");
                }
            });
        // 尺寸/scale 统筹：Dart 逻辑尺寸 → popup 物理池+viewport +
        // 引擎 metrics（pixelRatio=真实 scale → 渲染物理帧，无拉伸模糊）
        flutter_->setResizeHandler([this](int w, int h) {
            if (popup_) {
                popup_->setLogicalSize(w, h);
            }
            // metrics 更新 defer 到事件循环下一轮：resize 消息来自引擎平台
            // 回调、scale 来自 wayland dispatch——在这些上下文里同步调
            // SendWindowMetricsEvent 会与引擎内部锁重入死锁
            deferredMetrics(w, h);
        });
        // 合成器 scale 变化（跨屏移动/用户改缩放）→ 用当前逻辑尺寸重设 metrics
        popup_->setScaleHandler([this](double) {
            if (popup_ && popup_->logicalWidth() > 0) {
                deferredMetrics(popup_->logicalWidth(),
                                popup_->logicalHeight());
            }
        });
        // Dart → C++：resize 已由 embedder 截流（resizeHandler_）；panel 候选
        // 选择本地处理，其余（语音 select/hover/ready）回流引擎
        flutter_->setMessageHandler(
            [this](const std::string &method, const std::string &args) {
                onFlutterMessage(method, args);
            });
    } else {
        FCITX_INFO() << "AiInputUi: FlutterCard=False——不起 Flutter 引擎"
                        "（popup 以透明表面保留为 caret 数据源）";
    }
    // 光标矩形广播 → QML 卡 panel/caret（layer 重锚数据源）——两源合一：
    // wayland IC 经 popup 的 text_input_rectangle；D-Bus IC 经 rectWatcher
    // 的 ic->cursorRect()
    popup_->setCaretHandler([this](int x, int y, int w, int h) {
        FCITX_LOG(Info) << "AiInputUi: [caret] " << x << "," << y << " " << w
                        << "x" << h << " sock=" << (socketUi_ != nullptr);
        if (!socketUi_) {
            return;
        }
        socketUi_->sendEnvelope(
            "panel/caret",
            "{\"rect\":{\"x\":" + std::to_string(x) + ",\"y\":" +
                std::to_string(y) + ",\"w\":" + std::to_string(w) +
                ",\"h\":" + std::to_string(h) + "},\"space\":\"output\"}");
    });
    // 本 addon 的 ui 通道：panel/*（update() 本地翻译）直发 Dart。
    // voice/*、theme 走引擎 UiBus → deliverEnvelope，不经此 sender。
    // 双发：QML 卡 socket 镜像（同 deliverEnvelope）
    uiBus_.setSender([this](const std::string &method, const std::string &args) {
        if (flutter_ && flutter_->running()) {
            flutter_->sendMethod(method, args);
        }
        if (socketUi_) {
            socketUi_->sendEnvelope(method, args);
        }
    });

    // 预热：加载 5s 后初始化 Flutter 引擎（JIT 冷启动较慢，等触发再拉
    // 就晚了；失败则 uiShow 懒重试）+ popup 预热兜底（focus 事件可能早已
    // 错过；niri 对 IM popup 的 map 有 ~2s 流水线延迟，录音才建看不见卡）
    if (flutterCard_) {
        warmupTimer_ = instance_->eventLoop().addTimeEvent(
            CLOCK_MONOTONIC, nowUs() + 5000000, 0,
            [this](EventSourceTime *, uint64_t) {
                startFlutterEngine();
                if (popup_) {
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
    }

    // QML 卡片（M2 对比通道）：QmlCard=True 才建 socket 服务端 + 拉卡
    {
        const auto *qml = raw.valueByPath("QmlCard");
        FCITX_INFO() << "AiInputUi: QmlCard raw="
                     << (qml ? *qml : "(null)");
        if (qml && (*qml == "True" || *qml == "true")) {
            // 默认 abstract 名（无常驻 dentry，见 socket_ui.cpp listenUnix
            // 注释），带 uid 防同 netns 多用户撞名；显式 QmlCardSock 以
            // '/' 开头 = filesystem 路径（旧约定兼容），否则按 abstract 名
            std::string sock = "aiinput-card-" + std::to_string(getuid());
            if (const auto *s = raw.valueByPath("QmlCardSock");
                s && !s->empty()) {
                sock = *s;
            }
            std::string cmd;
            if (const auto *c = raw.valueByPath("QmlCardCmd"); c && !c->empty()) {
                cmd = *c;
            }
            if (cmd.empty()) {
                // ini 默认值不落文件（config 序列化层的概念），裸读须自备。
                // relay 模式（纯 QML 档）默认离屏渲染宿主——quickshell 的
                // grab 管线依赖合成器 expose，invisible 窗口回调丢失（
                // wip/qml-frame-relay 存档）；direct 模式（双卡对比）仍
                // quickshell 直显。宿主与本 .so 同目录（install 规则同往
                // libdir/fcitx5），/proc/self/exe 自定位 = 任意 install
                // 前缀/容器挂载都成立（编译期烤 CMAKE_INSTALL_PREFIX 会
                // 在非 /usr 构建里指回构建机路径——容器 relayhost13 实锤）
                if (!flutterCard_) {
                    // dladdr 取本 .so 路径（/proc/self/exe 是 fcitx5 主程
                    // 序，不是本库——容器 relayhost14 实锤 /usr/bin 误指）
                    Dl_info info{};
                    if (dladdr(reinterpret_cast<void *>(&AiInputUi::engine),
                               &info) &&
                        info.dli_fname) {
                        std::string dir(info.dli_fname);
                        auto slash = dir.rfind('/');
                        if (slash != std::string::npos) {
                            dir.resize(slash);
                            cmd = dir + "/aiinput-card-host --qml-dir " +
                                  dir + "/../../share/fcitx5-aiinput/card-qml";
                        }
                    }
                    if (cmd.empty()) {
                        // dladdr 失效的兜底（/usr 前缀安装时即正确值）
                        cmd = AIINPUT_CARD_HOST_PATH " --qml-dir "
                              AIINPUT_CARD_QML_DIR;
                    }
                } else {
                    cmd = "qs -p /usr/share/fcitx5-aiinput/card-qml";
                }
            }
            socketUi_ = std::make_unique<SocketUi>(
                instance_, sock, cmd, !flutterCard_,
                [this](const std::string &method, const std::string &args) {
                    // resize 是卡片自身布局语义，不回流（Flutter 卡的
                    // resize 才走引擎 metrics 统筹）
                    if (method == "resize") {
                        return;
                    }
                    if (method == "frame/ready") {
                        // frame-relay 文件中转：QML grab→saveToFile(P6)→
                        // 通知，C++ 读文件（二进制不过 socket 字符串语义）
                        auto path = jsonStrField(args, "path");
                        if (path.empty()) {
                            return;
                        }
                        std::ifstream f(path, std::ios::binary);
                        std::string ppm((std::istreambuf_iterator<char>(f)),
                                        std::istreambuf_iterator<char>());
                        handleFramePpm(reinterpret_cast<const uint8_t *>(
                                           ppm.data()),
                                       ppm.size());
                        return;
                    }
                    if (method.empty()) {
                        return;
                    }
                    if (auto *engine = this->engine()) {
                        engine->call<IAiInputEngine::uiCommand>(method, args);
                    }
                },
                [this](int w, int h, const uint8_t *data, size_t len) {
                    // 格式分发（见 SocketUi::FrameHandler）：P6 头 =
                    // PPM（quickshell 文件中转遗留）；其余 = 宿主直出
                    // premultiplied BGRA
                    if (len >= 2 && data[0] == 'P' && data[1] == '6') {
                        handleFramePpm(data, len);
                        return;
                    }
                    handleFrameBgra(w, h, data, len);
                });
        }
    }

    // 定位策略拉取：引擎构造期推送在本 addon 加载前发生（实测竞态 2.3ms
    // 差，推送静默丢弃）→ dbusFollow 停默认 false、D-Bus 前端应用跟随全
    // 灭。构造期直接查引擎实测拿不到（addon 装载阶段内查询不可靠），挪
    // 到事件循环首拍；引擎缺席 = 引擎稍后 reloadConfig 补发
    policyPullTimer_ = instance_->eventLoop().addTimeEvent(
        CLOCK_MONOTONIC, nowUs() + 100000, 0,
        [this](EventSourceTime *, uint64_t) {
            auto *e = engine();
            FCITX_INFO() << "AiInputUi: [policy-pull] engine=" << e;
            if (e) {
                e->call<IAiInputEngine::syncUiPolicy>();
            }
            // tray 使能接管：本 addon 以 UIPriority 胜出后 classicui 被
            // 管理器挂起，其 suspend() 会 disable SNI（fcitx5 托盘图标
            // 从此消失——0.4.11 接管以来的回归）。notificationitem 模块
            // 是独立实现（OnDemand），此处按需加载并使能，图标与菜单
            // （IM 切换/配置）随模块回归
            if (auto *ni = instance_->addonManager().addon("notificationitem",
                                                           true)) {
                ni->call<INotificationItem::enable>();
                FCITX_INFO() << "AiInputUi: [tray] notificationitem enabled="
                             << ni->call<INotificationItem::registered>();
            }
            return false; // 一次性
        });
    if (policyPullTimer_) {
        policyPullTimer_->setOneShot();
    }

    FCITX_INFO() << "AiInputUi: UI addon loaded";
}

AiInputUi::~AiInputUi() {
    // 故意泄漏 VoicePopup：addon unload 后 wayland display 仍会 dispatch
    // 若干轮（fractional scale/output 事件），销毁对象会让回调打进已释放
    // 内存（SIGTERM 退出即 SEGV）。进程退出统一回收
    (void)popup_.release();
}

AddonInstance *AiInputUiFactory::create(AddonManager *manager) {
    return new AiInputUi(manager->instance());
}

// 拆分契约：跨 addon 引用每次现取、空判静默降级（引擎缺席 = 无语音卡片）
AddonInstance *AiInputUi::engine() const {
    return instance_->addonManager().addon("aiinput", true);
}

bool AiInputUi::voiceSessionActive() {
    auto *engine = this->engine();
    return engine && engine->call<IAiInputEngine::voiceSessionActive>();
}

// —— UserInterface 实现（Category=UI：pinyin/rime 等引擎的候选窗）——
// update(InputPanel) 把 IC 的候选列表/预编辑翻译为 v1 panel/* 事件经本
// addon UiBus 直发。语音会话进行中不覆盖（录音/结果/候选态由引擎状态机
// 独占表面——voiceSessionActive 让位判定）
void AiInputUi::update(UserInterfaceComponent component,
                       InputContext *ic) {
    // 无条件日志：确认 fcitx5 是否调到了我们的 UI 接口
    FCITX_LOG(Info) << "AiInputUi: [ui] update(component="
                    << static_cast<int>(component) << " ic=" << ic << ")";
    if (component != UserInterfaceComponent::InputPanel || !ic) {
        return;
    }
    if (voiceSessionActive()) {
        return; // 语音会话活跃：面板让位
    }
    auto &panel = ic->inputPanel();
    if (panel.empty()) {
        // 面板清空：surface 同步退场（classicui 同款生命周期——popup 模式
        // hide 即销毁，下轮 showPanel 重建即拿到最新光标矩形/重夺定位槽）
        if (popup_) {
            popup_->hide();
        }
        uiBus_.panelHide();
        panelCandidates_.reset();
        panelIcRef_ = TrackableObjectReference<InputContext>();
        return;
    }
    // 候选窗上屏：解除帧守卫（visible_）——修复存量缺陷：panel 场景从无
    // show 路径，pushFrameBGRA 的 !visible_ 守卫把 Dart 候选窗帧全部丢弃
    //（容器 P4b 截图实证：帧画了、屏幕没有）。语音会话让位判定在上，
    // 与语音卡共用表面的竞争由该判定独占仲裁
    if (popup_) {
        popup_->showPanel(ic);
    }
    // 持有候选列表引用（异步点击选择时仍有效）
    panelCandidates_ = panel.candidateList();
    panelIcRef_ = ic->watch();

    // preedit → 数组 [{text, underline}]
    std::string preedit;
    const auto &preeditText = panel.preedit();
    if (!preeditText.empty()) {
        for (size_t i = 0; i < preeditText.size(); ++i) {
            auto fmt = preeditText.formatAt(i);
            preedit += "{\"text\":\"" +
                       flutterJsonEscape(preeditText.stringAt(i)) +
                       "\",\"underline\":" +
                       ((fmt & TextFormatFlag::Underline) ? "true" : "false") +
                       "},";
        }
        if (!preedit.empty()) preedit.pop_back(); // 尾逗号
    }
    preedit = "[" + preedit + "]";

    // 候选 → 数组 [{label, text, comment?}]
    std::string cands;
    int cursor = -1;
    auto list = panel.candidateList();
    if (list) {
        cursor = static_cast<int>(list->cursorIndex());
        for (int i = 0; i < static_cast<int>(list->size()); ++i) {
            auto &w = list->candidate(i);
            std::string label = list->label(i).toString();
            std::string text = w.text().toString();
#if defined(AIINPUT_FCITX_GE_51)
            std::string comment = w.comment().toString();
#else
            // fcitx5 5.0 无 CandidateWord::comment()——面板候选注释
            //（如拼音注音）降级为空，正文不受影响
            std::string comment;
#endif
            if (!cands.empty()) cands += ",";
            cands += "{\"label\":\"" + flutterJsonEscape(label) +
                     "\",\"text\":\"" + flutterJsonEscape(text);
            if (!comment.empty()) {
                cands += "\",\"comment\":\"" + flutterJsonEscape(comment);
            }
            cands += "\"}";
        }
    }
    cands = "[" + cands + "]";

    // 面板数据落地日志（rime 预编辑为空的取证：classicui 有而本面板无时
    // 对比此行即可定位丢在前端翻译还是渲染）
    FCITX_INFO() << "AiInputUi: [panel-data] preedit=" << preedit
                 << " auxUp=" << auxUp << " auxDown=" << auxDown
                 << " cands=" << cands.substr(0, 160);

    bool hasPrev = false, hasNext = false;
    if (list) {
        if (auto *pageable = list->toPageable()) {
            hasPrev = pageable->hasPrev();
            hasNext = pageable->hasNext();
        }
    }
    std::string layout = "horizontal";
    if (list) {
        auto hint = list->layoutHint();
        if (hint == CandidateLayoutHint::Vertical) {
            layout = "vertical";
        }
    }
    auto auxUp = panel.auxUp().toString();
    auto auxDown = panel.auxDown().toString();
    auto imName = instance_->currentInputMethod();

    uiBus_.panelUpdate(preedit, auxUp, auxDown, cands, cursor, layout,
                       hasPrev, hasNext, 0, imName);
}

bool AiInputUi::available() {
    // 无条件 true：Flutter 引擎 5s 预热期间 UI 选择不能跳过我们——
    // classicui 的 available() 同样恒 true。引擎未就绪时面板暂不渲染
    //（send 落空），就绪后下一次引擎 update() 即出面板
    return true;
}

void AiInputUi::suspend() {
    uiBus_.panelHide();
    panelCandidates_.reset();
}

void AiInputUi::resume() {
    // 无需主动恢复——下一次引擎 update() 会重推
}

// —— 引擎调用面 ——————————————————————————————————————————

void AiInputUi::deliverEnvelope(std::string method, std::string argsJson) {
    // 引擎 UiBus 的 sender 落点（voice/*、theme）：renderer 未起时丢弃
    //（引擎稍后经 ready/uiShow 重推，不需要排队）。双发：Flutter 卡 +
    // QML 卡（socket）镜像——双 UI 并行对比的通道基础
    if (flutter_ && flutter_->running()) {
        flutter_->sendMethod(method, argsJson);
    }
    if (socketUi_) {
        socketUi_->sendEnvelope(method, argsJson);
    }
}

void AiInputUi::uiPrepare(InputContext *ic) {
    // 预建 popup 并提交透明帧（niri 对 IM popup 的 map 有 ~2s 流水线延迟）
    if (popup_ && ic) {
        popup_->prepare(ic);
    }
}

void AiInputUi::uiShow(InputContext *ic) {
    if (!popup_ || !ic) {
        return;
    }
    // 懒兜底（预热失败/未到 5s 就触发；running 时幂等）。renderer 状态
    // 不外泄：失败回退色块由 popup 直接绘制，引擎不感知——voice envelope
    // 在 deliverEnvelope 处 guard，未起时丢弃。纯 QML 档不起色块（色块
    // 会真的上屏，QML 卡才是显示主体）
    startFlutterEngine();
    if (flutterCard_ && flutter_ && !flutter_->running()) {
        popup_->setPatternMode(true);
    }
    popup_->show(ic);
}

void AiInputUi::uiHide() {
    if (popup_) {
        popup_->hide();
    }
}

void AiInputUi::uiSetPolicy(std::string mode, std::string fallbackApps,
                            bool dbusFollow) {
    // 定位策略热更新（引擎 reloadConfig/setConfig 后下发；syncUiPolicy 拉
    // 取同款）。带值日志：加载竞态是否修复的判定锚点
    FCITX_INFO() << "AiInputUi: [policy] mode=" << mode
                 << " fallbackApps=" << fallbackApps
                 << " dbusFollow=" << dbusFollow;
    if (popup_) {
        popup_->setPositionPolicy(mode, fallbackApps);
        popup_->setDbusFollow(dbusFollow);
    }
}

// frame-relay 帧（PPM P6）→ BGRA → popup 物理帧直入
//（lab/spec/frame-relay.md；帧 socket 与文件中转两路共用）
void AiInputUi::handleFramePpm(const uint8_t *rgb, size_t len) {
    if (!popup_ || len < 16 || rgb[0] != 'P' || rgb[1] != '6') {
        return;
    }
    size_t i = 2;
    auto skipWsComments = [&]() {
        for (;;) {
            while (i < len &&
                   (rgb[i] == ' ' || rgb[i] == '\n' || rgb[i] == '\r' ||
                    rgb[i] == '\t'))
                ++i;
            if (i < len && rgb[i] == '#') {
                while (i < len && rgb[i] != '\n')
                    ++i;
            } else {
                break;
            }
        }
    };
    auto readInt = [&]() -> int {
        skipWsComments();
        int v = 0;
        while (i < len && rgb[i] >= '0' && rgb[i] <= '9') {
            v = v * 10 + (rgb[i] - '0');
            ++i;
        }
        return v;
    };
    skipWsComments(); // magic "P6"
    int w = readInt(), h = readInt(), maxv = readInt();
    if (w <= 0 || h <= 0 || w > 4096 || h > 4096 || maxv != 255) {
        return;
    }
    ++i; // 数据段前的单个空白
    size_t need = static_cast<size_t>(w) * h * 3;
    if (len - i < need) {
        return;
    }
    frameBgra_.assign(need / 3 * 4, 0);
    for (size_t px = 0; px < need / 3; ++px) {
        frameBgra_[px * 4] = rgb[i + px * 3 + 2];
        frameBgra_[px * 4 + 1] = rgb[i + px * 3 + 1];
        frameBgra_[px * 4 + 2] = rgb[i + px * 3];
        frameBgra_[px * 4 + 3] = 0xFF;
    }
    popup_->pushFrameRelay(w, h, frameBgra_.data());
    FCITX_LOG(Info) << "AiInputUi: [relay] frame " << w << "x" << h;
}

// 离屏宿主直出帧：premultiplied BGRA8888（带 alpha，圆角/阴影正常混合），
// 尺寸即物理像素，零转换直入 popup（PPM 路线的 alpha 丢失在此修复）
void AiInputUi::handleFrameBgra(int w, int h, const uint8_t *bgra, size_t len) {
    if (!popup_ || w <= 0 || h <= 0 || w > 4096 || h > 4096) {
        return;
    }
    if (len < static_cast<size_t>(w) * h * 4) {
        return;
    }
    popup_->pushFrameRelay(w, h, bgra);
    FCITX_LOG(Info) << "AiInputUi: [relay] frame " << w << "x" << h;
}

void AiInputUi::uiNotifyCommit() {
    // 上屏后通知（auto 模式继承跟随：chromium 系只在文本变化时报光标
    // 矩形，上屏 = handle 里有新鲜矩形可继承 → 下轮改回跟随）
    if (popup_) {
        popup_->notifyCommit();
    }
}

void AiInputUi::uiResolvePending() {
    // 录音结束仍无矩形：判定挂起结算到 layer（结果/候选卡片必须显示）
    if (popup_) {
        popup_->resolvePendingToLayer();
    }
}

void AiInputUi::uiPrimePreedit(InputContext *ic) {
    // 触发键按下时对未知能力 IC 提前挂探针（矩形窗口内即到 → 首下跟随）
    if (popup_ && ic) {
        popup_->primePreedit(ic);
    }
}

// —— Flutter 引擎 ——————————————————————————————————————————

void AiInputUi::startFlutterEngine() {
    if (!flutterCard_) {
        return; // 纯 QML 档：popup 保持透明（caret 数据源），引擎不起
    }
    if (flutter_->running()) {
        return;
    }
    std::string assets, icu;
    if (!findFlutterAssets(&assets, &icu)) {
        FCITX_WARN() << "AiInputUi: Flutter 资产未找到（"
                        "AIINPUT_FLUTTER_DIR 可覆盖；安装包应含 "
                        "/usr/share/fcitx5-aiinput/flutter）——回退色块模式";
        if (popup_) {
            popup_->setPatternMode(true);
        }
        return;
    }
    if (flutter_->start(assets, icu)) {
        // 引擎就绪即让引擎重推当前状态（Dart 冷启动有个过程）；Dart 自己
        // 的 ready 回流会再触发一次，幂等无害
        if (auto *engine = this->engine()) {
            engine->call<IAiInputEngine::uiCommand>("ready", "{}");
        }
    }
}

void AiInputUi::onFlutterMessage(const std::string &method,
                                 const std::string &args) {
    // {"index":N} / {"row":N}——极简字段提取（协议自约定）
    auto numOf = [](const std::string &s, const char *key) -> int {
        auto pos = s.find(std::string("\"") + key + "\":");
        if (pos == std::string::npos) {
            return -1;
        }
        return atoi(s.c_str() + pos + strlen(key) + 3);
    };
    if (method == "select") {
        const int idx = numOf(args, "index");
        if (args.find("\"panel\":true") != std::string::npos) {
            // panel 候选（pinyin 等）：CandidateWord::select——引擎自行
            // commit + 刷 InputPanel（引擎 update() 重推 panel/update）
            auto list = panelCandidates_.get();
            auto *ic = panelIcRef_.get();
            if (list && ic && idx >= 0 &&
                idx < static_cast<int>(list->size())) {
                list->candidate(static_cast<size_t>(idx)).select(ic);
            }
            return;
        }
    }
    // 其余（语音候选 select/hover/ready）回流引擎状态机处理
    if (auto *engine = this->engine()) {
        engine->call<IAiInputEngine::uiCommand>(method, args);
    }
}

// metrics 更新统一 defer（防 dispatch/平台回调上下文重入引擎锁）
void AiInputUi::deferredMetrics(int w, int h) {
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

} // namespace fcitx

FCITX_ADDON_FACTORY(fcitx::AiInputUiFactory)
