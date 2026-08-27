#ifndef _FCITX5_AIINPUT_POPUP_SURFACE_H_
#define _FCITX5_AIINPUT_POPUP_SURFACE_H_

#include <fcitx/instance.h>
#include <fcitx-utils/event.h>
#include <fcitx-utils/handlertable.h>
#include <fcitx-utils/trackableobject.h>
#include <fcitx/event.h>
#include <xcb/shm.h>
#include <xcb/xcb.h>
#include <wayland_public.h>

#include <functional>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <utility>
#include <map>
#include <vector>

struct wl_display;
struct wl_registry;
struct wl_compositor;
struct wl_shm;
struct wl_seat;
struct wl_output;
struct wl_pointer;
struct wl_surface;
struct wl_shm_pool;
struct wl_buffer;
struct wp_viewporter;
struct wp_viewport;
struct wp_fractional_scale_manager_v1;
struct wp_fractional_scale_v1;
struct zwp_input_method_v2;
struct zwp_input_popup_surface_v2;
struct zwlr_layer_shell_v1;
struct zwlr_layer_surface_v1;
struct wp_cursor_shape_manager_v1;
struct wp_cursor_shape_device_v1;
struct zxdg_output_manager_v1;
struct zxdg_output_v1;

// 每输出几何（多显示器：scale 按表面所在输出推导）
struct OutputGeom {
    int32_t physW = 0, physH = 0;          // wl_output mode
    int32_t logicalW = 0, logicalH = 0;    // zxdg_output logical_size
    int32_t logicalX = 0, logicalY = 0;    // zxdg_output logical_position
    double scale() const {
        return (logicalW > 0 && physW > 0)
                   ? static_cast<double>(physW) / logicalW : 0;
    }
    // XWayland 的输出区段：位置=逻辑原点、范围=物理尺寸（xrandr 实测：
    // X 屏把每个输出按物理大小摆进逻辑布局——X 坐标是物理像素）
    bool containsXPoint(int32_t x, int32_t y) const {
        return physW > 0 && x >= logicalX && y >= logicalY &&
               x < logicalX + physW && y < logicalY + physH;
    }
};

namespace fcitx {
class InputContext;
}

namespace fcitx::wayland {
class ZwpInputMethodV2;
}

// 来自 fcitx5 src/frontend/waylandim/waylandim_public.h（该头文件未随
// fcitx5 包安装，此处 vendor 声明；跨 addon 调用按名字+签名在运行时匹配）
FCITX_ADDON_DECLARE_FUNCTION(
    WaylandIMModule, getInputMethodV2,
    fcitx::wayland::ZwpInputMethodV2 *(fcitx::InputContext *));

namespace fcitx {

/**
 * zwp_input_popup_surface_v2 浮窗（classicui 同款定位方式）。
 *
 * 关键约束：一个 seat 只允许一个 zwp_input_method_v2，waylandim 模块已经
 * bind（本 addon 的 IC 即来自它）。因此不自建 IM 连接，而是复用
 * waylandim 的 IM proxy：IWaylandIMModule::getInputMethodV2(ic) 取 wrapper →
 * rawPointer() 提取 raw proxy → zwp_input_method_v2_get_input_popup_surface()
 * 挂 popup role。popup 只有在 IM 处于 activate 状态时才会被合成器 map 到
 * 光标矩形附近（text_input_rectangle 事件）。
 *
 * 生命周期照抄 classicui（waylandinputwindow.cpp）：hide 即销毁 popup+surface
 * （pool/buffers 复用）；show(ic) 时若有 IC 切换则重建；缓冲内容由
 * Flutter 帧写入（桥不可用时回退色块测试帧）。
 *
 * 线程：wayland 事件在 fcitx 主循环（wayland 模块把 fd 挂进 instance）；
 * show/hide 由状态机主线程调用，wl_proxy_marshal/flush 线程安全。
 */
class VoicePopup {
public:
    explicit VoicePopup(Instance *instance);
    ~VoicePopup();

    bool ready();
    // 预建：IC 激活时创建 popup 并提交透明帧（niri 对 IM popup 的 map 有
    // ~2s 延迟，提前走完 map 流水线，录音开始即可实时换帧）
    void prepare(InputContext *ic);
    // 显示（ic 用于取 waylandim 的 IM proxy）。
    // flutter 模式：只确保 popup 就绪，等首帧 commit；色块模式（桥不可用
    // 时的回退）立即绘制测试帧
    void show(InputContext *ic);
    void hide();
    // Flutter 帧入口。写入一帧 BGRA（wl_shm ARGB8888 小端字节序，
    // 引擎软渲输出可直接 memcpy），尺寸变化时自动重建 shm 池
    void pushFrameBGRA(const uint8_t *bgra, int w, int h);
    void resize(int w, int h); // 重建 shm 池（帧尺寸变化；内部加锁）
    void resizeLocked(int w, int h); // 已持锁版本（wayland 回调用）
    void setPatternMode(bool p) { patternMode_ = p; } // 引擎不可用时回退色块

    // —— 卡片定位模式（chromium 系不报光标矩形 → input popup 被合成器
    // 放到窗口左上角；此类应用改用 layer-shell 自定位）——
    void setPositionPolicy(const std::string &mode,
                           const std::string &fallbackAppsCsv);
    // overlay 兜底层（DBus 前端 IC）的贴光标档（DbusPosition=follow）：
    // 卡片锚到 IC 光标矩形下方（矩形坐标系前提见 anchorOverlayLocked）
    void setDbusFollow(bool follow);
    // 本 IC 我们上屏过文本。chromium 系只在**文本变化时**报光标矩形：
    // 上屏即意味着合成器 handle 里有新鲜矩形可供 show 重建的 popup
    // 继承 → auto 模式下轮改回跟随
    void notifyCommit();
    // 录音结束仍无矩形：判定挂起结算到 layer（结果/候选卡片必须显示）
    void resolvePendingToLayer();
    // 预输入探针：把可见组合文本「语音输入中」逐字打进 client preedit
    //（classicui 拼音候选窗实时跟随的同款机制）——组合变化逼应用重报
    // 光标矩形，卡片被合成器实时挪到当前光标。preedit 永不入文，上屏
    // 时 commitString 按协议替换（自清洁）。只在 caret 模式用（layer
    // 自定位无意义）。调用方持锁或主循环单线程
    void beginPreeditProbe(InputContext *ic);
    void endPreeditProbe();
    // 探针逐字打出：一次性整串 set 只有一次组合变化、报文可有可无；
    // 逐字 = 每字一次组合变化 = 每字一次报文机会
    void typeProbeNext(InputContext *ic);
    // surface 切换（结算回退 layer）或判定挂起解除（矩形到达放开首帧）
    // 时回调：引擎需要向新 surface 重推一帧 UI
    void setModeSwitchHandler(std::function<void()> h) {
        modeSwitchHandler_ = std::move(h);
    }
    // 触发键按下时（阈值判定窗口内）对未知能力的 IC 提前挂探针：
    // 矩形在窗口内即到，show 决策已有知识 → 首下跟随而非回退
    void primePreedit(InputContext *ic);

    // fractional scale：逻辑/物理尺寸分离。Dart（或调用方）上报**逻辑**
    // 尺寸；池按 物理=ceil(逻辑×scale/120) 建，viewport 缩回逻辑显示。
    // scale 经 preferred_scale 事件异步到达后自动重算并回调（metrics 需更新）
    void setLogicalSize(int w, int h);
    // 生效 scale：fractional 事件（精确，1/120）优先；未到则用上次
    // fractional 记忆，最后退 wl_output 整数 scale
    // 只读标量缓存：aiinput 的 metrics 定时器不持锁调用，容器遍历会与
    // registry/xdg 回调竞争——锁内事件点 recomputeScaleLocked 更新
    double scale() const { return cachedScale_ > 0 ? cachedScale_ : 1.0; }
    void recomputeScaleLocked();
    int logicalWidth() const { return logicalW_; }
    int logicalHeight() const { return logicalH_; }
    // scale 变化回调（aiinput 据此更新引擎 metrics 重渲物理帧）
    void setScaleHandler(std::function<void(double)> h) {
        scaleHandler_ = std::move(h);
    }

    // 指针事件原始转发（不做 C++ 侧命中测试——Flutter 引擎直接收
    // FlutterPointerEvent，hover/点击由 Dart 命中）。niri 的 IM popup 不
    // 在窗口/层 surface 树里，seat 级 wl_pointer 才能收到表面局部坐标
    enum class PointerEvent { Enter, Leave, Motion, Press, Release };
    void setPointerSink(
        std::function<void(PointerEvent kind, int x, int y)> sink) {
        pointerSink_ = std::move(sink);
    }

    // wayland C 回调（public：listener 结构需要函数指针）
    static void registryGlobalImpl(void *data, wl_registry *reg, uint32_t name,
                                   const char *iface, uint32_t version);
    static void registryGlobalRemoveImpl(void *data, wl_registry *reg,
                                         uint32_t name);
    static void popupRectangle(void *data, zwp_input_popup_surface_v2 *popup,
                               int32_t x, int32_t y, int32_t w, int32_t h);
    // seat 级指针路由（niri 上 IM popup 不收指针事件，见 setClickHandler）
    static void seatCapabilities(void *data, wl_seat *seat, uint32_t caps);
    static void outputGeometry(void *data, wl_output *o, int32_t, int32_t,
                               int32_t, int32_t, int32_t, const char *,
                               const char *, int32_t);
    static void outputMode(void *data, wl_output *o, uint32_t, int32_t,
                           int32_t, int32_t);
    static void outputScale(void *data, wl_output *o, int32_t factor);
    static void outputDone(void *data, wl_output *o);
    static void pointerEnter(void *data, wl_pointer *p, uint32_t serial,
                             wl_surface *surface, wl_fixed_t sx, wl_fixed_t sy);
    static void pointerLeave(void *data, wl_pointer *p, uint32_t serial,
                             wl_surface *surface);
    static void pointerMotion(void *data, wl_pointer *p, uint32_t time,
                              wl_fixed_t sx, wl_fixed_t sy);
    static void pointerButton(void *data, wl_pointer *p, uint32_t serial,
                              uint32_t time, uint32_t button, uint32_t state);
    static void preferredScale(void *data, wp_fractional_scale_v1 *fs,
                               uint32_t scale);
    static void xdgLogicalSize(void *data, zxdg_output_v1 *xo, int32_t w,
                           int32_t h);
    static void xdgLogicalPos(void *data, zxdg_output_v1 *xo, int32_t x,
                              int32_t y);
    static void surfaceEnter(void *data, wl_surface *s, wl_output *o);
    static void surfaceLeave(void *data, wl_surface *s, wl_output *o);
    static void layerConfigure(void *data, zwlr_layer_surface_v1 *ls,
                               uint32_t serial, uint32_t w, uint32_t h);

private:
    void onConnectionCreated(const std::string &name, wl_display *display);
    // wayland 监听注册（构造时可能未加载：定时重试 + prepare 兜底；
    // 不持锁调用——对已建立连接注册回调会立即同步触发 onConnectionCreated）
    void ensureWaylandWatcher();
    void scheduleWatcherRetry();
    int watcherTries_ = 0;
    std::unique_ptr<EventSourceTime> watcherRetry_;
    void setupDisplay(wl_display *display);
    bool ensurePopup(InputContext *ic, bool atShow = false); // IC 变化时重建 surface+popup
    void destroyPopupSurface();
    void syncViewportLocked(); // destination 与匹配 buffer 同 commit 下发
    void teardown();
    bool wantTopMode(InputContext *ic, bool atShow = false); // 定位模式决策（policy × 名单 × 矩形上报能力）
    // overlay 兜底层的锚定：follow 档按 IC 光标矩形贴光标（含翻转/钳
    // 制），默认/无矩形底部（或 policy 的顶部）居中。持锁调用
    void anchorOverlayLocked(InputContext *ic);
    // XWayland 应用判定 + X 卡片窗生命周期。XShm 帧入口在
    // pushFrameBGRA 的 x11Mode_ 分支
    void ensureX11Atoms();
    // 首帧建窗（OR，物理尺寸，位置=矩形下方）并贴帧；后续帧只 put
    void pushFrameX11Locked(const uint8_t *bgra, int w, int h);
    void destroyX11WindowLocked(); // unmap+销毁+SHM 释放
    void moveX11WindowLocked(const Rect &rect); // 矩形变化重摆
    // X 卡片落点（caret 下方放不下翻上、钳入输出 X 区段）。持锁
    std::pair<int, int> x11CardPosLocked(const Rect &rect, int cardW,
                                         int cardH);
    static constexpr int kGapX11 = 8;
    std::string toLower(std::string s);

    Instance *instance_;
    std::mutex mutex_;

    // wayland 资源（im_ 借自 waylandim，绝不 destroy）
    wl_display *display_ = nullptr;
    wl_registry *registry_ = nullptr;
    wl_compositor *compositor_ = nullptr;
    uint32_t compositorVersion_ = 1; // damage_buffer 需 ≥4
    wl_shm *shm_ = nullptr;
    wl_seat *seat_ = nullptr;
    wl_pointer *pointer_ = nullptr;
    // 指针可见性（enter 后须设光标，否则合成器隐藏）
    wp_cursor_shape_manager_v1 *cursorShapeMgr_ = nullptr;
    wp_cursor_shape_device_v1 *cursorShapeDev_ = nullptr;
    wp_viewporter *viewporter_ = nullptr;
    wp_viewport *viewport_ = nullptr;
    wp_fractional_scale_manager_v1 *fsManager_ = nullptr;
    wp_fractional_scale_v1 *fscale_ = nullptr;
    uint32_t scaleNum_ = 120; // 1/120 单位（协议约定 120=1.0）
    bool gotFscale_ = false;  // fractional 事件是否到达过
    // 最后一次 fractional 值（跨 surface 记忆）：layer surface 可能收不到
    // fractional 事件，此时整数兜底 wl_output scale 是向上取整值（混
    // scale 双屏上会放大 33-60%）→ 用上次 fractional 兜底永远更准
    uint32_t lastFscaleNum_ = 0;
    int outputScale_ = 1;     // wl_output 整数 scale 兜底
    zxdg_output_manager_v1 *xdgOutputMgr_ = nullptr;
    // 多输出：全部输出几何 + 表面所在输出（enter/leave 跟踪）
    std::map<wl_output *, OutputGeom> outputs_;
    std::map<zxdg_output_v1 *, wl_output *> xdgOwner_; // xdg 对象→输出
    wl_output *output_ = nullptr;        // 首输出（整数 scale 兜底）
    wl_output *surfaceOutput_ = nullptr; // 本表面当前所在输出
    double cachedScale_ = 0; // 锁内解析的有效 scale（事件点更新）
    int logicalW_ = 0, logicalH_ = 0;
    std::function<void(double)> scaleHandler_;

    zwp_input_method_v2 *im_ = nullptr; // 借用：waylandim 所有
    zwp_input_popup_surface_v2 *popup_ = nullptr;
    wl_surface *surface_ = nullptr;

    // —— XWayland 卡片路径（X 应用的 D-Bus IC：classicui 同款传输层）——
    // xwayland-satellite 把 override-redirect X 窗转成 xdg_popup 挂到
    // 聚焦 X 顶层窗（源码 create_role_window: popup_for = last_hovered
    // || last_focused_toplevel；offset=Δ/scale），合成器自动叠加应用窗口
    // 真实屏幕原点——右列/多输出/缩放全由 satellite+niri 处理。X 应用
    // 经 D-Bus 报的光标矩形不含窗口原点（satellite 把所有顶层 X 窗摆在
    // 根 (0,0)，mapToGlobal 是窗口局部物理值），wayland 层表面无从得知
    // 原点——只能走 X 侧
    xcb_connection_t *xconn_ = nullptr;
    xcb_window_t xroot_ = XCB_WINDOW_NONE;
    int xRootW_ = 0, xRootH_ = 0; // X 屏尺寸（satellite root）：卡片硬边界
    int xFocusW_ = 0, xFocusH_ = 0; // 聚焦 X 顶层窗尺寸（卡片首要边界）
    bool xTried_ = false, xBroken_ = false;
    bool xActiveLast_ = false; // 活动窗判定结果（日志去重）
    int xErrLog_ = 0;          // X 错误日志限流
    std::map<std::string, bool> xClassCache_; // program → 是否 X 应用
    uint32_t xAtomActiveWindow_ = XCB_ATOM_NONE, xAtomWmClass_ = XCB_ATOM_NONE,
             xAtomClientList_ = XCB_ATOM_NONE;
    // OR 卡片窗（x11Mode_）：XShm 帧缓冲 + 事件源 + GC
    bool x11Mode_ = false;
    xcb_window_t xwin_ = XCB_WINDOW_NONE;
    xcb_gcontext_t xgc_ = XCB_NONE;
    xcb_visualid_t xVisual_ = 0;  // 32 位 ARGB（无则退化 root_visual）
    xcb_colormap_t xColormap_ = XCB_NONE;
    uint8_t xDepth_ = 24;
    xcb_shm_seg_t xshm_ = XCB_NONE;
    int xshmid_ = -1;
    uint8_t *xshmAddr_ = nullptr;
    size_t xshmSize_ = 0;
    int xwinW_ = 0, xwinH_ = 0;
    Rect xLastRect_; // 最近光标矩形（首帧建窗定位 + 重摆）
    std::unique_ptr<EventSourceIO> xEventSrc_;
    void handleX11Events();          // xcb fd 可读：poll 事件队列
    void ensureX11EventSource();     // xconn_ fd → fcitx 事件循环
    // 聚焦应用是否 X 应用：_NET_ACTIVE_WINDOW 存在（satellite 在 wayland
    // 聚焦时清空它——FocusIn 的 IC 即聚焦应用，无需 program/WM_CLASS）
    bool focusedX11WindowLocked();
    // 刷新聚焦 X 顶层窗几何到 xFocusW_/H_（仅建窗日志观测，不参与摆位）
    void queryFocusGeometryLocked();
    // 矩形是否为 X 物理坐标（超出全部输出逻辑范围——X 应用铁证）
    bool rectIsXPhysical(const Rect &rect);
    // program 异步到达的补判：矩形变化时 layer → X OR 窗升级。持锁调用
    void tryUpgradeToX11Locked(InputContext *ic);

    // layer-shell 回退（chromium 系；anchorBottom_ 底部居中为默认，兼容
    // 旧值 "top" 顶部居中）
    zwlr_layer_shell_v1 *layerShell_ = nullptr;
    zwlr_layer_surface_v1 *layerSurface_ = nullptr;
    bool layerConfigured_ = false; // 首个 configure 到达前不得 commit buffer
    bool topMode_ = false;         // 当前 surface 用的是 layer 角色
    bool overlayFallback_ = false; // layer 角色因 DBus 前端 IC（无 IM
                                   // proxy，跟随不可达）强制——建在
                                   // overlay 层（高于启动器面板）并挂探针
    std::string positionMode_ = "auto";
    std::vector<std::string> fallbackApps_;
    bool dbusFollow_ = false; // overlay 兜底层贴光标（DbusPosition=follow）
    int lastAnchorTop_ = -1, lastAnchorLeft_ = -1; // 锚定落点（日志去重）
    std::unique_ptr<HandlerTableEntry<EventHandler>> rectWatcher_;
    void *surfaceCompat_ = nullptr; // WlSurface wrapper 布局占位（见 cpp）
    wl_region *emptyRegion_ = nullptr; // 隐藏/透明态的空输入区域
    TrackableObjectReference<InputContext> icRef_; // popup 所属 IC
    // 本 IC 自激活以来是否收到过"真实"（非 0x0）光标矩形。chromium 系
    // 恒 0,0 0x0 → auto 模式据此回退 layer-shell；GTK/Qt 焦点后很快上报
    bool sawRealRect_ = false;
    // 本 IC 是否上屏过文本（我们自己 commitString）——chromium 的矩形
    // 只在文本变化时上报，上屏 = handle 里必有新鲜矩形可继承
    bool committedInThisIC_ = false;
    bool anchorBottom_ = true; // layer 模式锚点：false=顶部居中（仅显式
                               // "top"），true=底部居中（默认）
    int popupAttachCount_ = 0; // popup 模式 attach 计数（>1 即重建）
    bool preeditProbeActive_ = false; // 预输入探针是否在挂
    int probeTypingIdx_ = 0; // 探针逐字进度（5=打完）
    std::unique_ptr<EventSourceTime> probeTypeTimer_;
    // 应用级跟随知识（进程生命周期）：矩形事件或上屏记账成功过的程序
    // 名集合——重聚焦产生新 IC 时凭此首下即跟随（Electron 的 text-input
    // 按会话重建 IC，IC 级标志每次清零）
    std::string lastProgram_;
    std::set<std::string> followingApps_;
    bool lastDecisionWasKnowledgeFallback_ = false; // wantTopMode 的回退分支
    bool probeDeferralUsed_ = false; // 本会话已用过二次探测暂缓（防递归）
    bool decisionPending_ = false; // 判定挂起：帧不上屏直到跟随/底部定局
    std::function<void()> modeSwitchHandler_;
    void armProbeFallbackTimer();
    void resolvePendingToLayerLocked(); // 持锁版（保险丝/结算共用）
    std::unique_ptr<EventSourceTime> probeTimer_;

    // 指针路由状态
    bool hasCursorRect_ = false; // text_input_rectangle 是否已送达（决策门）
    bool pointerOnPopup_ = false; // 指针焦点在我们 popup 表面（直达模式）
    std::function<void(PointerEvent, int, int)> pointerSink_;
    int ptrX_ = -10000, ptrY_ = -10000; // 最近指针位置（表面局部）

    // shm 双缓冲
    wl_shm_pool *pool_ = nullptr;
    wl_buffer *buffers_[2] = {nullptr, nullptr};
    uint8_t *pixels_ = nullptr; // mmap 的整个池
    size_t poolCapacity_ = 0;   // 池容量字节（桶内 resize 只换 buffer）
    int poolFd_ = -1;
    int cur_ = 0;
    int width_ = 0, height_ = 0;

    bool visible_ = false;
    bool patternMode_ = false; // 桥不可用时回退色块测试帧
    int cursorX_ = 0, cursorY_ = 0, cursorW_ = 0, cursorH_ = 0; // 光标矩形
    // 矩形事件去重：mutter 会每帧重发同值矩形（实测 ~300/s，7 分钟
    // 12.6 万条日志淹没事件循环、拖死 D-Bus）——同值直接丢
    int rectLastX_ = -1, rectLastY_ = -1, rectLastW_ = -1, rectLastH_ = -1;

    std::unique_ptr<HandlerTableEntry<WaylandConnectionCreated>>
        connHandler_;
    std::unique_ptr<HandlerTableEntry<WaylandConnectionClosed>>
        closeHandler_;
};

} // namespace fcitx

#endif // _FCITX5_AIINPUT_POPUP_SURFACE_H_
