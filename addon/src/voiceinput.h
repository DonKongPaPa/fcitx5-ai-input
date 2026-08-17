#ifndef _FCITX5_VOICEINPUT_VOICEINPUT_H_
#define _FCITX5_VOICEINPUT_VOICEINPUT_H_

#include <fcitx-utils/dbus/objectvtable.h>
#include <fcitx/addonfactory.h>
#include <fcitx/addoninstance.h>
#include <fcitx/inputmethodengine.h>
#include <fcitx/instance.h>

#include <memory>

namespace fcitx {

class VoiceInputEngine;

/**
 * 测试钩子：org.fcitx.VoiceInput.Test / Trigger(text)
 * 管线通过 D-Bus 触发提交，避免在三种桌面环境下模拟键盘按键。
 * M3+ 在此扩展：延迟埋点时间戳、ASR/LLM 引擎切换等测试接口。
 */
class TestService : public dbus::ObjectVTable<TestService> {
public:
    TestService(VoiceInputEngine *engine) : engine_(engine) {}

    std::string Trigger(std::string text);

    static const char *interface() { return "org.fcitx.VoiceInput.Test"; }

private:
    VoiceInputEngine *engine_;
    FCITX_OBJECT_VTABLE_METHOD(Trigger, "Trigger", "s", "s");
};

class VoiceInputEngine : public InputMethodEngine {
public:
    VoiceInputEngine(Instance *instance);
    ~VoiceInputEngine() override;

    void activate(const InputMethodEntry &entry,
                  InputContextEvent &event) override;
    void keyEvent(const InputMethodEntry &entry,
                  KeyEvent &keyEvent) override;

    Instance *instance() { return instance_; }

private:
    void ensureTestService();

    Instance *instance_;
    dbus::Bus *bus_ = nullptr;
    std::unique_ptr<TestService> testService_;
};

class VoiceInputEngineFactory : public AddonFactory {
public:
    AddonInstance *create(AddonManager *manager) override;
};

} // namespace fcitx

#endif // _FCITX5_VOICEINPUT_VOICEINPUT_H_
