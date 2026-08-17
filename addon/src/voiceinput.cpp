#include "voiceinput.h"
#include "popup_surface.h"
#include "ui_bridge.h"

#include <fcitx-config/iniparser.h>
#include <fcitx-utils/keysym.h>
#include <fcitx-utils/log.h>
#include <fcitx/addonmanager.h>
#include <fcitx/inputcontextmanager.h>

#include <dbus_public.h>

namespace fcitx {

static uint64_t nowUs() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<uint64_t>(ts.tv_sec) * 1000000 + ts.tv_nsec / 1000;
}

VoiceInputEngine::VoiceInputEngine(Instance *instance)
    : instance_(instance) {
    // 配置：~/.config/fcitx5/conf/voiceinput.config（不存在则用默认值）
    readAsIni(config_, "conf/voiceinput.config");
    reloadConfig();

    asr_ = std::make_unique<DummyAsrEngine>();
    popup_ = std::make_unique<VoicePopup>(instance_);
    bridge_ = std::make_unique<UiBridge>(instance_, popup_.get());

    // 注册测试 D-Bus 服务（addon 加载期 dbus 未就绪时由 activate 补注册）
    ensureTestService();
    FCITX_INFO() << "VoiceInput engine loaded (config: mode="
                 << TriggerModeToString(config_.triggerMode.value())
                 << " keys=" << config_.triggerKeys.value().size()
                 << " dummyText=\"" << config_.dummyText.value() << "\")";
}

VoiceInputEngine::~VoiceInputEngine() = default;

AddonInstance *VoiceInputEngineFactory::create(AddonManager *manager) {
    return new VoiceInputEngine(manager->instance());
}

void VoiceInputEngine::reloadConfig() {
    readAsIni(config_, "conf/voiceinput.config");
    uiNotify("config-reloaded");
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

void VoiceInputEngine::activate(const InputMethodEntry & /*entry*/,
                                InputContextEvent &event) {
    ensureTestService();
    // 预热 flutter UI：IC 首次激活即拉起（冷启动 ~3s，等录音才拉就晚了）
    if (bridge_) {
        bridge_->ensureStarted();
    }
    if (state_ == State::Idle) {
        sessionIc_ = event.inputContext();
        // 预建 popup（透明帧提前走完 niri ~2s 的 map 流水线）
        if (popup_ && sessionIc_) {
            popup_->prepare(sessionIc_);
        }
    }
    uiNotify("activated");
}

// ---------------------------------------------------------------------------
// 状态机
// ---------------------------------------------------------------------------

bool VoiceInputEngine::isTriggerKey(const Key &key) const {
    for (const auto &k : config_.triggerKeys.value()) {
        if (k.check(key)) {
            return true;
        }
    }
    return false;
}

void VoiceInputEngine::keyEvent(const InputMethodEntry & /*entry*/,
                                KeyEvent &keyEvent) {
    auto *ic = keyEvent.inputContext();
    if (handleKey(keyEvent.key(), !keyEvent.isRelease(), ic)) {
        keyEvent.filterAndAccept();
    }
}

bool VoiceInputEngine::handleKey(const Key &key, bool pressed,
                                 InputContext *ic) {
    // —— 候选状态：数字/Enter/Esc ——
    if (state_ == State::Candidates && pressed) {
        if (key.check(FcitxKey_Return) || key.check(FcitxKey_KP_Enter)) {
            commitCandidate(0, ic);
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
    }

    const bool trigger = isTriggerKey(key);

    switch (state_) {
    case State::Idle:
        if (trigger && pressed) {
            sessionIc_ = ic;
            state_ = State::Pressing;
            startThresholdTimer();
            uiNotify("pressing");
            return true; // 按下即吞（引擎激活时触发键归输入法所有）
        }
        break;

    case State::Pressing:
        if (trigger && !pressed) {
            // 未到阈值松开：吞掉 release，状态回 Idle（press 未透传）
            thresholdTimer_.reset();
            enterIdle();
            return true;
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
            if (sessionIc_) {
                sessionIc_->commitString(finalText_);
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
                beginRecording(sessionIc_);
            }
            return true;
        });
    if (thresholdTimer_) {
        thresholdTimer_->setOneShot();
    }
}

void VoiceInputEngine::beginRecording(InputContext *ic) {
    state_ = State::Recording;
    toggleReleased_ = false;
    recordStartUs_ = nowUs();
    if (popup_) {
        popup_->show(ic);
    }
    if (bridge_ && bridge_->ensureStarted()) {
        bridge_->sendRecording("", 0);
    } else {
        // 桥不可用：回退 F3 色块（popup 直接绘制）
        if (popup_) {
            popup_->setPatternMode(true);
            popup_->show(ic);
        }
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
    if (bridge_) {
        bridge_->sendRecording(partial_, (nowUs() - recordStartUs_) / 1000);
    }
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
        if (bridge_) {
            bridge_->sendCandidates(finalText_, candidates_);
        }
        uiNotify("candidates", joinCandidates());
    } else {
        state_ = State::Result;
        if (bridge_) {
            bridge_->sendResult(finalText_,
                                config_.popupTimeoutMs.value());
        }
        uiNotify("result", finalText_);
        startResultTimer();
    }
}

void VoiceInputEngine::startResultTimer() {
    resultTimer_.reset();
    resultTimer_ = instance_->eventLoop().addTimeEvent(
        CLOCK_MONOTONIC, nowUs() + config_.popupTimeoutMs.value() * 1000, 0,
        [this](EventSourceTime *, uint64_t) {
            if (state_ == State::Result && sessionIc_) {
                sessionIc_->commitString(finalText_);
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
    } else if (sessionIc_) {
        sessionIc_->commitString(text);
    }
    uiNotify("committed", text);
    enterIdle();
}

void VoiceInputEngine::enterIdle() {
    if (popup_) {
        popup_->hide();
    }
    if (bridge_) {
        bridge_->sendIdle();
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
    // F2 日志桩；F3/F4 替换为 popup surface / Flutter 通道
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

std::string TestService::State() { return engine_->stateName(); }

std::vector<std::string> TestService::Candidates() {
    return engine_->candidates();
}

} // namespace fcitx

FCITX_ADDON_FACTORY(fcitx::VoiceInputEngineFactory)
