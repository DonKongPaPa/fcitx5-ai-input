#include "voiceinput.h"

#include <fcitx-utils/log.h>
#include <fcitx/addonmanager.h>

namespace fcitx {

VoiceInputEngine::VoiceInputEngine(Instance *instance)
    : instance_(instance) {
    // M1 骨架：仅验证 addon 能被 fcitx5 加载
    // 后续里程碑在此接入：D-Bus 服务、录音、ASR/LLM 引擎抽象、悬浮窗定位
    FCITX_INFO() << "VoiceInput engine loaded (skeleton)";
}

VoiceInputEngine::~VoiceInputEngine() = default;

AddonInstance *VoiceInputEngineFactory::create(AddonManager *manager) {
    FCITX_INFO() << "Creating VoiceInputEngine";
    return new VoiceInputEngine(manager->instance());
}

void VoiceInputEngine::activate(const InputMethodEntry & /*entry*/,
                                InputContextEvent & /*event*/) {
    FCITX_INFO() << "VoiceInput activated";
}

void VoiceInputEngine::keyEvent(const InputMethodEntry & /*entry*/,
                                KeyEvent & /*keyEvent*/) {
    // 骨架阶段：不处理任何按键，全部透传
}

} // namespace fcitx

FCITX_ADDON_FACTORY(fcitx::VoiceInputEngineFactory)
