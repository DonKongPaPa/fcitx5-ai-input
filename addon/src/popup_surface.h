#ifndef _FCITX5_VOICEINPUT_POPUP_SURFACE_H_
#define _FCITX5_VOICEINPUT_POPUP_SURFACE_H_

#include <fcitx/instance.h>
#include <fcitx-utils/trackableobject.h>
#include <wayland_public.h>

#include <functional>
#include <memory>
#include <mutex>
#include <string>
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
 * （pool/buffers 复用）；show(ic) 时若有 IC 切换则重建；缓冲不透明由
 * F3 色块 / F4 Flutter 帧写入。
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
    // F4→重构：Flutter 引擎进程内嵌入后的帧入口。写入一帧 BGRA
    //（wl_shm ARGB8888 小端字节序，引擎软渲输出可直接 memcpy），
    // 尺寸变化时自动重建 shm 池
    void pushFrameBGRA(const uint8_t *bgra, int w, int h);
    void resize(int w, int h); // 重建 shm 池（帧尺寸变化；内部加锁）
    void resizeLocked(int w, int h); // 已持锁版本（wayland 回调用）
    void setPatternMode(bool p) { patternMode_ = p; } // 引擎不可用时回退色块

    // —— 卡片定位模式（chromium 系不报光标矩形 → input popup 被合成器
    // 放到窗口左上角；此类应用改用 layer-shell 自定位）——
    void setPositionPolicy(const std::string &mode,
                           const std::string &fallbackAppsCsv);
    // 本 IC 我们上屏过文本。chromium 系只在**文本变化时**报光标矩形
    //（实验 007/r26）：上屏即意味着 smithay handle 里有新鲜矩形可供
    // show 重建的 popup 继承 → auto 模式下轮改回跟随
    void notifyCommit();

    // W3 fractional scale：逻辑/物理尺寸分离。Dart（或调用方）上报**逻辑**
    // 尺寸；池按 物理=ceil(逻辑×scale/120) 建，viewport 缩回逻辑显示。
    // scale 经 preferred_scale 事件异步到达后自动重算并回调（metrics 需更新）
    void setLogicalSize(int w, int h);
    // 生效 scale：fractional 事件（精确，1/120）优先；未到则用 wl_output
    // 整数 scale（niri 不给 IM popup 发 fractional preferred_scale，实测）
    double scale() const {
        return gotFscale_ ? scaleNum_ / 120.0 : outputScale_;
    }
    int logicalWidth() const { return logicalW_; }
    int logicalHeight() const { return logicalH_; }
    // scale 变化回调（voiceinput 据此更新引擎 metrics 重渲物理帧）
    void setScaleHandler(std::function<void(double)> h) {
        scaleHandler_ = std::move(h);
    }

    // P3→重构：指针事件原始转发（不再 C++ 侧命中测试——Flutter 引擎直接
    // 收 FlutterPointerEvent，hover/点击由 Dart 命中）。niri 的 IM popup 不
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
    static void layerConfigure(void *data, zwlr_layer_surface_v1 *ls,
                               uint32_t serial, uint32_t w, uint32_t h);

private:
    void onConnectionCreated(const std::string &name, wl_display *display);
    void setupDisplay(wl_display *display);
    bool ensurePopup(InputContext *ic, bool atShow = false); // IC 变化时重建 surface+popup
    void destroyPopupSurface();
    void teardown();
    bool wantTopMode(InputContext *ic, bool atShow = false); // 定位模式决策（policy × 名单 × 矩形上报能力）
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
    wp_viewporter *viewporter_ = nullptr;
    wp_viewport *viewport_ = nullptr;
    wp_fractional_scale_manager_v1 *fsManager_ = nullptr;
    wp_fractional_scale_v1 *fscale_ = nullptr;
    uint32_t scaleNum_ = 120; // 1/120 单位（协议约定 120=1.0）
    bool gotFscale_ = false;  // fractional 事件是否到达过
    int outputScale_ = 1;     // wl_output 整数 scale 兜底
    wl_output *output_ = nullptr;
    int logicalW_ = 0, logicalH_ = 0;
    std::function<void(double)> scaleHandler_;

    zwp_input_method_v2 *im_ = nullptr; // 借用：waylandim 所有
    zwp_input_popup_surface_v2 *popup_ = nullptr;
    wl_surface *surface_ = nullptr;

    // layer-shell 回退（chromium 系；anchorBottom_ 底部居中为默认，兼容
    // 旧值 "top" 顶部居中）
    zwlr_layer_shell_v1 *layerShell_ = nullptr;
    zwlr_layer_surface_v1 *layerSurface_ = nullptr;
    bool layerConfigured_ = false; // 首个 configure 到达前不得 commit buffer
    bool topMode_ = false;         // 当前 surface 用的是 layer 角色
    std::string positionMode_ = "auto";
    std::vector<std::string> fallbackApps_;
    void *surfaceCompat_ = nullptr; // WlSurface wrapper 布局占位（见 cpp）
    wl_region *emptyRegion_ = nullptr; // 隐藏/透明态的空输入区域
    TrackableObjectReference<InputContext> icRef_; // popup 所属 IC
    // 本 IC 自激活以来是否收到过"真实"（非 0x0）光标矩形。chromium 系
    // 恒 0,0 0x0 → auto 模式据此回退 layer-shell；GTK/Qt 焦点后很快上报
    bool sawRealRect_ = false;
    // 本 IC 是否上屏过文本（我们自己 commitString）——chromium 的矩形
    // 只在文本变化时上报，上屏 = handle 里必有新鲜矩形可继承
    bool committedInThisIC_ = false;
    bool anchorBottom_ = true; // layer 模式锚点：false=顶部居中（仅旧值
                               // "top"），true=底部居中（默认，用户偏好）
    int popupAttachCount_ = 0; // popup 模式 attach 计数（>1 即重建）

    // 指针路由状态
    bool hasCursorRect_ = false; // text_input_rectangle 是否已送达（决策门）
    bool pointerOnPopup_ = false; // 指针焦点在我们 popup 表面（直达模式）
    std::function<void(PointerEvent, int, int)> pointerSink_;
    int ptrX_ = -10000, ptrY_ = -10000; // 最近指针位置（表面局部）

    // shm 双缓冲
    wl_shm_pool *pool_ = nullptr;
    wl_buffer *buffers_[2] = {nullptr, nullptr};
    uint8_t *pixels_ = nullptr; // mmap 的整个池
    int poolFd_ = -1;
    int cur_ = 0;
    int width_ = 0, height_ = 0;

    bool visible_ = false;
    bool patternMode_ = false; // 桥不可用时回退 F3 色块
    bool isImConnection_ = false; // registry 见到 IM manager 即 waylandim 连接
    int cursorX_ = 0, cursorY_ = 0, cursorW_ = 0, cursorH_ = 0; // 光标矩形

    std::unique_ptr<HandlerTableEntry<WaylandConnectionCreated>>
        connHandler_;
    std::unique_ptr<HandlerTableEntry<WaylandConnectionClosed>>
        closeHandler_;
};

} // namespace fcitx

#endif // _FCITX5_VOICEINPUT_POPUP_SURFACE_H_
