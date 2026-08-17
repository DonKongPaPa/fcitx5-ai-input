#ifndef _FCITX5_VOICEINPUT_VOICEINPUT_H_
#define _FCITX5_VOICEINPUT_VOICEINPUT_H_

#include "asr_engine.h"
#include "voiceinput_config.h"

#include <fcitx-utils/dbus/objectvtable.h>
#include <fcitx/addonfactory.h>
#include <fcitx/addoninstance.h>
#include <fcitx/inputmethodengine.h>
#include <fcitx/instance.h>

#include <memory>

namespace fcitx {

class VoiceInputEngine;

/**
 * 测试钩子（管线用，免容器键盘合成）：
 *  - Trigger(text)：直接提交文本（M1 起保留，兼容既有用例）
 *  - SimulateKey(key, pressed)：模拟触发键按下/松开（走真实状态机路径）
 *  - State()：查询状态机当前状态（断言用）
 *  - Candidates()：查询当前候选列表
 */
class TestService : public dbus::ObjectVTable<TestService> {
public:
    TestService(VoiceInputEngine *engine) : engine_(engine) {}

    std::string Trigger(std::string text);
    std::string SimulateKey(std::string key, bool pressed);
    std::string State();
    std::vector<std::string> Candidates();

    static const char *interface() { return "org.fcitx.VoiceInput.Test"; }

private:
    VoiceInputEngine *engine_;
    FCITX_OBJECT_VTABLE_METHOD(Trigger, "Trigger", "s", "s");
    FCITX_OBJECT_VTABLE_METHOD(SimulateKey, "SimulateKey", "sb", "s");
    FCITX_OBJECT_VTABLE_METHOD(State, "State", "", "s");
    FCITX_OBJECT_VTABLE_METHOD(Candidates, "Candidates", "", "as");
};

/**
 * 语音输入引擎。
 *
 * 状态机：
 *   Idle ─触发键按下─▶ Pressing ─阈值到─▶ Recording ─停止─▶ Result/Candidates
 *     ▲                   │松开(未到阈值)                      │选择/超时
 *     └───────────────────┴───────────────────────────────────┘
 *
 *   Recording:
 *     HoldRelease 模式：松开触发键 → 结束
 *     Toggle 模式：忽略起始松开，下一次按下 → 结束
 *   Result（LLM 关）：展示 popupTimeoutMs 后自动 commit
 *   Candidates（LLM 开）：润色/原始候选，数字1-9/Enter/Esc 选择
 */
class VoiceInputEngine : public InputMethodEngine {
public:
    VoiceInputEngine(Instance *instance);
    ~VoiceInputEngine() override;

    void activate(const InputMethodEntry &entry,
                  InputContextEvent &event) override;
    void keyEvent(const InputMethodEntry &entry,
                  KeyEvent &keyEvent) override;

    // configtool 设置页：Configuration 自动生成 UI；保存经 D-Bus 触发 reload
    void reloadConfig() override;
    const Configuration *getConfig() const override { return &config_; }

    Instance *instance() { return instance_; }

    // 状态机内部入口（TestService::SimulateKey 复用，keyEvent 只是薄封装）
    // 返回 true = 按键被消费（不透传给应用）
    bool handleKey(const Key &key, bool pressed, InputContext *ic);

    std::string stateName() const;
    const std::vector<std::string> &candidates() const { return candidates_; }
    void commitCandidate(size_t index, InputContext *ic);

private:
    enum class State { Idle, Pressing, Recording, Result, Candidates };

    void beginRecording(InputContext *ic);
    void finishRecording();
    void onAsrFinish(const std::string &text);
    void onAsrPartial(const std::string &text);
    void enterIdle();
    void startThresholdTimer();
    void startResultTimer();
    void ensureTestService();
    std::string joinCandidates() const;

    bool isTriggerKey(const Key &key) const;
    static std::string polish(const std::string &text);

    // —— UI 通知（F2 为日志桩；F3/F4 接 popup surface / Flutter）——
    void uiNotify(const std::string &what, const std::string &detail = "");

    Instance *instance_;
    VoiceInputConfig config_;
    dbus::Bus *bus_ = nullptr;
    std::unique_ptr<TestService> testService_;

    State state_ = State::Idle;
    InputContext *sessionIc_ = nullptr;
    bool toggleReleased_ = false; // Toggle 模式：起始按的键已松开
    std::unique_ptr<EventSourceTime> thresholdTimer_;
    std::unique_ptr<EventSourceTime> resultTimer_;
    std::unique_ptr<AsrEngine> asr_;
    std::string partial_;                 // 当前流式中间文本
    std::string finalText_;              // ASR 最终文本
    std::vector<std::string> candidates_; // LLM 候选（[0]=润色 [1]=原始 ...）
};

class VoiceInputEngineFactory : public AddonFactory {
public:
    AddonInstance *create(AddonManager *manager) override;
};

} // namespace fcitx

#endif // _FCITX5_VOICEINPUT_VOICEINPUT_H_
