#ifndef _FCITX5_VOICEINPUT_VOICEINPUT_H_
#define _FCITX5_VOICEINPUT_VOICEINPUT_H_

#include "asr_engine.h"
#include "voiceinput_config.h"

#include <fcitx-config/rawconfig.h>
#include <fcitx-utils/dbus/objectvtable.h>
#include <fcitx-utils/handlertable.h>
#include <fcitx/addonfactory.h>
#include <fcitx/addoninstance.h>
#include <fcitx/event.h>
#include <fcitx/instance.h>
#include <fcitx-utils/trackableobject.h>

#include <atomic>
#include <memory>

namespace fcitx {

class VoicePopup;
class FlutterEngineHost;
class VoiceInputEngine;

/**
 * 测试钩子（管线用，免容器键盘合成）：
 *  - Trigger(text)：直接提交文本（M1 起保留，兼容既有用例）
 *  - SimulateKey(key, pressed)：模拟触发键按下/松开（走真实状态机路径）
 *  - InjectKey(key, pressed)：postEvent 真实事件管线（验证 PreInputMethod
 *    拦截与透传语义，SimulateKey 绕过了 watcher）
 *  - State()：查询状态机当前状态（断言用）
 *  - Candidates()：查询当前候选列表
 */
class TestService : public dbus::ObjectVTable<TestService> {
public:
    TestService(VoiceInputEngine *engine) : engine_(engine) {}

    std::string Trigger(std::string text);
    std::string SimulateKey(std::string key, bool pressed);
    std::string InjectKey(std::string key, bool pressed);
    std::string State();
    std::string Version();
    std::string HealthCheck(std::string mode);
    std::vector<std::string> Candidates();

    static const char *interface() { return "org.fcitx.VoiceInput.Test"; }

private:
    VoiceInputEngine *engine_;
    FCITX_OBJECT_VTABLE_METHOD(Trigger, "Trigger", "s", "s");
    FCITX_OBJECT_VTABLE_METHOD(SimulateKey, "SimulateKey", "sb", "s");
    FCITX_OBJECT_VTABLE_METHOD(InjectKey, "InjectKey", "sb", "s");
    FCITX_OBJECT_VTABLE_METHOD(State, "State", "", "s");
    FCITX_OBJECT_VTABLE_METHOD(Version, "Version", "", "s");
    FCITX_OBJECT_VTABLE_METHOD(HealthCheck, "HealthCheck", "s", "s");
    FCITX_OBJECT_VTABLE_METHOD(Candidates, "Candidates", "", "as");
};

/**
 * 语音输入 addon（Module，不注册输入法条目）。
 *
 * 与其他输入法（rime/pinyin…）共存：无需切换输入法，触发键经
 * Instance::watchEvent(InputContextKeyEvent, PreInputMethod) 在引擎之前
 * 拦截（官方"独立模式 addon"工作流，同 clipboard 模块）；识别结果直接
 * commitString 到焦点 IC。悬浮窗借 waylandim 的 IM proxy（classicui 同款），
 * UI 由进程内嵌入的 Flutter 引擎软渲（无窗口/无独立进程）。
 *
 * 触发键消费策略（共存的关键，见 keyWatcher 注释）：
 *   - 触发键事件本身永不 filter：press 已透传给应用，release 必须配对，
 *     否则应用 xkb 状态卡在"Ctrl 按下"；lone modifier 对应用是 no-op
 *   - Pressing 态任意其他键 → 取消候选（Ctrl+S 类组合不受扰，全透传）
 *   - Recording/Result/Candidates 模态：其余键全部吞掉（Esc/数字/Enter
 *     /方向键/空格 由状态机处理，防止击键漏进 rime/应用）
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
 *   Candidates（LLM 开）：润色/原始候选，数字1-9/Enter/Esc/方向键/空格选择
 */
class VoiceInputEngine : public AddonInstance {
public:
    VoiceInputEngine(Instance *instance);
    ~VoiceInputEngine() override;

    // configtool 设置页：Configuration 自动生成 UI。注意保存链路是
    // D-Bus SetConfig → setConfig()（基类默认 no-op，不实现则 configtool
    // 点保存毫无效果）；文件直改路径走 reloadConfig()
    void reloadConfig() override;
    const Configuration *getConfig() const override { return &config_; }
    void setConfig(const RawConfig &config) override;

    Instance *instance() { return instance_; }

    // 状态机内部入口（TestService::SimulateKey 复用，keyWatcher 只是薄封装）
    // 返回 true = 按键被状态机处理
    bool handleKey(const Key &key, bool pressed, InputContext *ic);

    std::string stateName() const;
    std::string healthCheckJson(bool deep); // TestService::HealthCheck 调
    std::string resolveUiFont();
    void sendFontToUi();
    // 字体解析后台线程 → pipe 唤醒主循环（fontconfig 锁与 pango 死锁）
    int fontPipe_[2] = {-1, -1};
    std::unique_ptr<EventSourceIO> fontIo_;
    std::mutex fontMutex_;
    std::string fontJson_;
    std::atomic<bool> fontResolving_{false};
    void deferredMetrics(int w, int h);
    std::unique_ptr<EventSourceTime> metricsTimer_;
    int pendingMW_ = 64, pendingMH_ = 64;
    const std::vector<std::string> &candidates() const { return candidates_; }
    void commitCandidate(size_t index, InputContext *ic);
    // 上屏后通知 popup（auto 模式继承跟随；TestService::Trigger 也走这里）
    void notifyUiCommit();

private:
    enum class State { Idle, Pressing, Recording, Result, Candidates };

    void migrateLegacyConfig();
    // 上屏后注入 Left+Right 无净位移键对：应用的光标矩形重报只发生在
    // 光标移动/文本变化时（GTK 程序性 commit 不重报、chromium 报插入
    // 点），逼它按真实光标重报，下一轮卡片不再"迟一步"
    void nudgeCaretRect(InputContext *ic);

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

    // —— 部署健康检查 / 引擎切换联动 ——
    void onEngineChanged(AsrEngineKind next);
    void runServerScript(const std::string &cmd, const std::string &action);
    AsrEngineKind lastEngine_ = AsrEngineKind::Dummy;

    // —— Flutter（进程内嵌入引擎）——
    void startFlutterEngine();
    void pushUiState();                  // 状态机 → Dart update 推送
    void onFlutterMessage(const std::string &method,
                          const std::string &argsJson);

    // —— UI 通知（日志，测试断言用）——
    void uiNotify(const std::string &what, const std::string &detail = "");

    Instance *instance_;
    VoiceInputConfig config_;
    std::unique_ptr<VoicePopup> popup_;
    std::unique_ptr<FlutterEngineHost> flutter_;
    dbus::Bus *bus_ = nullptr;
    std::unique_ptr<TestService> testService_;

    // 全局按键拦截（PreInputMethod：rime 等引擎之前）
    std::unique_ptr<HandlerTableEntry<EventHandler>> keyWatcher_;
    std::unique_ptr<HandlerTableEntry<EventHandler>> focusWatcher_; // popup 预热
    std::unique_ptr<EventSourceTime> warmupTimer_; // 加载后预热引擎
    std::unique_ptr<EventSourceTime> dbusRetry_;   // dbus 模块未就绪时补注册

    State state_ = State::Idle;
    // 会话 IC 用 watch() 跟踪：裸指针会在 hold 的 300ms 窗口内因焦点
    // 切换/IC 销毁变成悬垂指针（宿主机实测 beginRecording→getInputMethodV2
    // →frontendName SEGV）
    TrackableObjectReference<InputContext> sessionIcRef_;
    bool toggleReleased_ = false; // Toggle 模式：起始按的键已松开
    std::unique_ptr<EventSourceTime> thresholdTimer_;
    std::unique_ptr<EventSourceTime> tailTimer_; // 松开后尾音宽限 350ms
    std::unique_ptr<EventSourceTime> resultTimer_;
    std::unique_ptr<AsrEngine> asr_;
    std::string partial_;                 // 当前流式中间文本
    std::string finalText_;               // ASR 最终文本
    std::vector<std::string> candidates_; // LLM 候选（[0]=润色 [1]=原始 ...）
    uint64_t recordStartUs_ = 0;          // 录音起点（推 elapsed_ms）
    int uiHoverRow_ = -1;                 // Dart 回报的鼠标 hover 行
    int keyboardRow_ = 0;                 // 候选态键盘方向键选择行
};

class VoiceInputEngineFactory : public AddonFactory {
public:
    AddonInstance *create(AddonManager *manager) override;
};

} // namespace fcitx

#endif // _FCITX5_VOICEINPUT_VOICEINPUT_H_
