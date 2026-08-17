#ifndef _FCITX5_VOICEINPUT_VOICEINPUT_H_
#define _FCITX5_VOICEINPUT_VOICEINPUT_H_

#include <fcitx/addonfactory.h>
#include <fcitx/addoninstance.h>
#include <fcitx/inputmethodengine.h>
#include <fcitx/instance.h>

namespace fcitx {

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
    Instance *instance_;
};

class VoiceInputEngineFactory : public AddonFactory {
public:
    AddonInstance *create(AddonManager *manager) override;
};
} // namespace fcitx

#endif // _FCITX5_VOICEINPUT_VOICEINPUT_H_
