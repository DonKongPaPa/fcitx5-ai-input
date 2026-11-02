#ifndef _FCITX5_AIINPUT_HUB_UI_SPLIT_IFACE_H_
#define _FCITX5_AIINPUT_HUB_UI_SPLIT_IFACE_H_

// UI 插件化拆分的跨 addon 接口契约（设计文档：lab/spec/ui-split-contract.md）。
//
// 绑定机制与 popup_surface.h 对 waylandim 的 vendor 声明同款：按
// "类名::函数名" 字符串 + 签名在运行时匹配。EXPORT 侧必须用同名类：
//   - UI addon 实现类 AiInputUi（addon conf：aiinput-ui.conf，名字 "aiinput-ui"）
//   - 引擎 addon 实现类 AiInputEngine（addon conf：aiinput.conf，名字 "aiinput"）
// DECLARE 侧生成 I<Name> 代理，调用式：
//   uiAddon->call<IAiInputUi::uiShow>(ic);
//   engineAddon->call<IAiInputEngine::uiCommand>("ready", "{}");
//
// 消息路由（v1 envelope 不变）：
//   - voice/*、theme：引擎 UiBus sender=deliverEnvelope → UI addon → flutter
//   - panel/*：UI addon 的 UserInterface::update 本地翻译直发（fcitx5 的
//     update 回调物理落在 Category=UI 的 aiinput-ui 上，不经引擎）

#include <string>

#include <fcitx/addoninstance.h>

namespace fcitx {

class InputContext;

} // namespace fcitx

// DECLARE 宏自身展开 namespace fcitx（上游 xcb_public.h/wayland_public.h
// 同款）——必须在全局作用域调用：namespace 内调用会把特例化嵌进
// fcitx::fcitx，落在非包围命名空间，编译期即报错
// —— aiinput-ui 导出面（引擎调用；无 UI addon 时引擎空判静默降级）——
// UiBus sender 落点：转发 voice/*、theme 到 Flutter platform channel
FCITX_ADDON_DECLARE_FUNCTION(AiInputUi, deliverEnvelope,
                             void(std::string, std::string));
// 焦点预热：预建 popup 并提交透明帧（niri IM popup map 有 ~2s 流水线延迟）
FCITX_ADDON_DECLARE_FUNCTION(AiInputUi, uiPrepare, void(fcitx::InputContext *));
// 录音开始显示卡片：内部含 renderer 懒启动与色块回退（引擎不感知渲染状态）
FCITX_ADDON_DECLARE_FUNCTION(AiInputUi, uiShow, void(fcitx::InputContext *));
FCITX_ADDON_DECLARE_FUNCTION(AiInputUi, uiHide, void());
// 定位策略热更新（reloadConfig/setConfig 后下发）
FCITX_ADDON_DECLARE_FUNCTION(AiInputUi, uiSetPolicy,
                             void(std::string, std::string, bool));
// 上屏后通知（auto 模式继承跟随）
FCITX_ADDON_DECLARE_FUNCTION(AiInputUi, uiNotifyCommit, void());
// 录音结束仍无矩形：判定挂起结算到 layer（结果/候选卡片必须显示）
FCITX_ADDON_DECLARE_FUNCTION(AiInputUi, uiResolvePending, void());
// 触发键按下时对未知能力 IC 提前挂探针（矩形窗口内即到 → 首下跟随）
FCITX_ADDON_DECLARE_FUNCTION(AiInputUi, uiPrimePreedit,
                             void(fcitx::InputContext *));

// —— aiinput 导出面（UI addon 调用）——
// Dart 命令回流：select（语音候选）/hover/ready；UI 侧 surface 切换等
// 需要引擎重推状态时也走 uiCommand("ready", "{}")
FCITX_ADDON_DECLARE_FUNCTION(AiInputEngine, uiCommand,
                             void(std::string, std::string));
// update() 让位判定：语音会话（Recording/Result/Candidates）活跃时
// 拼音面板不覆盖语音卡片
FCITX_ADDON_DECLARE_FUNCTION(AiInputEngine, voiceSessionActive, bool());
// 定位策略重推（uiSetPolicy）：M1 拆分后引擎构造先于 UI addon 加载
//（实测 2.3ms 差），构造期推送被静默丢弃 → popup 的 dbusFollow 停在
// 默认 false、D-Bus 前端应用（DMS/WPS）近似跟随全灭。UI addon 加载完
// 主动拉取一次，消除对加载顺序的依赖
FCITX_ADDON_DECLARE_FUNCTION(AiInputEngine, syncUiPolicy, void());

#endif // _FCITX5_AIINPUT_HUB_UI_SPLIT_IFACE_H_
