#ifndef _FCITX5_AIINPUT_UI_ADDON_H_
#define _FCITX5_AIINPUT_UI_ADDON_H_

#include "ui_split_iface.h" // 导出签名对参（EXPORT 宏编译期校验）

#include <fcitx-utils/event.h>
#include <fcitx-utils/handlertable.h>
#include <fcitx-utils/trackableobject.h>
#include <fcitx/addonfactory.h>
#include <fcitx/candidatelist.h>
#include <fcitx/instance.h>
#include <fcitx/userinterface.h>

#include <memory>
#include <vector>
#include <string>

#include "socket_ui.h"
#include "ui_bus.h"

namespace fcitx {

class VoicePopup;
class FlutterEngineHost;

/**
 * aiinput-ui：语音卡片的 UI addon（Category=UI，UserInterface 实现）。
 *
 * 持有 VoicePopup（光标跟随/layer/XWayland 三条定位路径全随之）与进程内
 * Flutter 引擎（软渲 → wl_shm 帧直写）。update() 把 IC 的候选/预编辑翻译
 * 为 v1 panel/* 事件直发 Dart（本 addon 自己的 UiBus，不经引擎）。
 *
 * 跨 addon 接口见 hub/ui_split_iface.h：引擎调 deliverEnvelope/ui* 驱动
 * 语音卡片；本 addon 调引擎 uiCommand/voiceSessionActive 回流命令与做
 * 让位判定。两侧 addon 引用都每次现取、空判静默降级（任一缺席 = 对应
 * 能力关闭，另一侧照常工作）。
 */
class AiInputUi : public UserInterface {
public:
    AiInputUi(Instance *instance);
    ~AiInputUi() override;

    // —— UserInterface 四方法（fcitx5 经 Category=UI 路由到本 addon）——
    // update(InputPanel)：IC 的候选/预编辑/辅助文本 → v1 panel/* 事件。
    // 语音会话进行中不覆盖（让位判定查引擎 voiceSessionActive）
    void update(UserInterfaceComponent component,
                InputContext *inputContext) override;
    bool available() override;
    void suspend() override;
    void resume() override;

    // —— 引擎调用面（ui_split_iface.h 导出，全部空判 popup_ 静默降级）——
    // voice/*、theme envelope 落点：renderer 未起时丢弃（引擎稍后经
    // ready/uiShow 重推，不需要排队）
    void deliverEnvelope(std::string method, std::string argsJson);
    void uiPrepare(InputContext *ic);
    void uiShow(InputContext *ic);
    void uiHide();
    void uiSetPolicy(std::string mode, std::string fallbackApps,
                     bool dbusFollow);
    // 候选面板排列钉死（PanelLayout=auto/horizontal/vertical；auto=跟随
    // 输入法布局提示）
    void uiSetPanelLayout(std::string layout);
    FCITX_ADDON_EXPORT_FUNCTION(AiInputUi, uiSetPanelLayout);
    void uiNotifyCommit();
    void uiResolvePending();
    void uiPrimePreedit(InputContext *ic);

    FCITX_ADDON_EXPORT_FUNCTION(AiInputUi, deliverEnvelope);
    FCITX_ADDON_EXPORT_FUNCTION(AiInputUi, uiPrepare);
    FCITX_ADDON_EXPORT_FUNCTION(AiInputUi, uiShow);
    FCITX_ADDON_EXPORT_FUNCTION(AiInputUi, uiHide);
    FCITX_ADDON_EXPORT_FUNCTION(AiInputUi, uiSetPolicy);
    FCITX_ADDON_EXPORT_FUNCTION(AiInputUi, uiNotifyCommit);
    FCITX_ADDON_EXPORT_FUNCTION(AiInputUi, uiResolvePending);
    FCITX_ADDON_EXPORT_FUNCTION(AiInputUi, uiPrimePreedit);

private:
    // 引擎 addon 现取（缺席返回 null——拆分契约：静默降级不报错）
    AddonInstance *engine() const;
    // update() 让位判定 = 引擎 voiceSessionActive()（引擎缺席 = 不活跃）
    bool voiceSessionActive();
    // FlutterCard=False（纯 QML 验证档）：不建 popup 表面不起 Flutter 引擎
    bool flutterCard_ = true;

    // —— Flutter（进程内嵌入引擎）——
    void startFlutterEngine();
    // Dart 命令分流：select{"panel":true} 本地处理，其余回流引擎
    void onFlutterMessage(const std::string &method,
                          const std::string &argsJson);
    // metrics 更新统一 defer（防 dispatch/平台回调上下文重入引擎锁）
    void deferredMetrics(int w, int h);
    // frame-relay 帧入口（格式按 payload 首字节分发，见 SocketUi::FrameHandler）
    void handleFramePpm(const uint8_t *rgb, size_t len);
    // 离屏宿主直出帧：premultiplied BGRA（带 alpha）零转换直入 popup
    void handleFrameBgra(int w, int h, const uint8_t *bgra, size_t len);

    Instance *instance_;
    std::unique_ptr<VoicePopup> popup_;
    UiBus uiBus_; // 本 addon 的 ui 通道发射器：panel/* 直发（sender=embedder）
    // QML 卡片通道（M2）：envelope 镜像 + 卡片回写回流（QmlCard=True 才建）
    std::unique_ptr<SocketUi> socketUi_;
    std::vector<uint8_t> frameBgra_; // PPM→BGRA 转换复用缓冲
    // IM 面板状态（pinyin/rime 候选——update() 写、Dart panel select 读）
    std::shared_ptr<CandidateList> panelCandidates_;
    TrackableObjectReference<InputContext> panelIcRef_;
    std::string panelLayout_ = "auto"; // PanelLayout 钉死（auto=跟随提示）
    std::unique_ptr<FlutterEngineHost> flutter_;
    std::unique_ptr<EventSourceTime> warmupTimer_; // 加载后预热引擎+popup
    std::unique_ptr<EventSourceTime> policyPullTimer_; // 加载后拉定位策略
    std::unique_ptr<EventSourceTime> metricsTimer_;
    int pendingMW_ = 64, pendingMH_ = 64;
};

class AiInputUiFactory : public AddonFactory {
public:
    AddonInstance *create(AddonManager *manager) override;
};

} // namespace fcitx

#endif // _FCITX5_AIINPUT_UI_ADDON_H_
