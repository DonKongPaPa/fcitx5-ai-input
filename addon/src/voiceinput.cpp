#include "voiceinput.h"

#include <fcitx-utils/log.h>
#include <fcitx/addonmanager.h>
#include <dbus_public.h>

namespace fcitx {

VoiceInputEngine::VoiceInputEngine(Instance *instance)
    : instance_(instance) {
    FCITX_INFO() << "VoiceInput engine loaded (skeleton)";
    // addon 加载阶段不可重入（dbus 模块可能尚未加载），activate 时再补注册
    ensureTestService();
}

VoiceInputEngine::~VoiceInputEngine() = default;

AddonInstance *VoiceInputEngineFactory::create(AddonManager *manager) {
    FCITX_INFO() << "Creating VoiceInputEngine";
    return new VoiceInputEngine(manager->instance());
}

void VoiceInputEngine::activate(const InputMethodEntry & /*entry*/,
                                InputContextEvent & /*event*/) {
    FCITX_INFO() << "VoiceInput activated";
    ensureTestService();
}

void VoiceInputEngine::ensureTestService() {
    if (testService_) {
        return;
    }
    // addon(name, true) 强制加载 dbus 模块；构造期可能未就绪，activate 时会重试
    auto *dbus = instance_->addonManager().addon("dbus", true);
    if (!dbus) {
        FCITX_WARN() << "dbus module unavailable, test hook disabled";
        return;
    }
    bus_ = dbus->call<IDBusModule::bus>();
    if (!bus_) {
        FCITX_WARN() << "dbus bus unavailable";
        return;
    }
    testService_ = std::make_unique<TestService>(this);
    bus_->addObjectVTable("/org/fcitx/VoiceInput", "org.fcitx.VoiceInput.Test",
                          *testService_);
    FCITX_INFO() << "VoiceInput test D-Bus service registered";
}

void VoiceInputEngine::keyEvent(const InputMethodEntry & /*entry*/,
                                KeyEvent & /*keyEvent*/) {
    // 骨架阶段：不处理任何按键，全部透传
}

std::string TestService::Trigger(std::string text) {
    auto *ic = engine_->instance()->inputContextManager()
                   .lastFocusedInputContext();
    if (!ic) {
        return "error: no focused input context";
    }
    ic->commitString(text);
    FCITX_INFO() << "Test Trigger committed: " << text;
    return "ok: " + std::string(text);
}

} // namespace fcitx

FCITX_ADDON_FACTORY(fcitx::VoiceInputEngineFactory)
