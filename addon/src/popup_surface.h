#ifndef _FCITX5_VOICEINPUT_POPUP_SURFACE_H_
#define _FCITX5_VOICEINPUT_POPUP_SURFACE_H_

#include <fcitx/instance.h>
#include <fcitx-utils/trackableobject.h>
#include <wayland_public.h>

#include <functional>
#include <memory>
#include <mutex>

struct wl_display;
struct wl_registry;
struct wl_compositor;
struct wl_shm;
struct wl_seat;
struct wl_pointer;
struct wl_surface;
struct wl_shm_pool;
struct wl_buffer;
struct zwp_input_method_v2;
struct zwp_input_popup_surface_v2;

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
    // F4 帧桥入口：写入一帧 RGBA（w×h），尺寸变化时自动重建 shm 池
    void pushFrame(const uint8_t *rgba, int w, int h);
    void resize(int w, int h); // 重建 shm 池（帧尺寸变化）
    void setPatternMode(bool p) { patternMode_ = p; } // 桥不可用回退色块

    // P3 鼠标路由：niri 的 IM popup 不收指针事件（命中测试只走窗口/层
    // surface 树），点击会落到下层窗口——seat 级 wl_pointer 能收到该窗口
    // 局部坐标，配合 text_input_rectangle（同为窗口局部）+ 放置规则做命中
    void setClickHandler(std::function<void(int row)> h) {
        clickHandler_ = std::move(h);
    }
    void setHoverHandler(std::function<void(int row)> h) {
        hoverHandler_ = std::move(h);
    }
    // 当前 popup 在焦点窗口坐标系里的候选行命中（-1=不在面板上）
    int pointerRow(int winX, int winY) const;

    // wayland C 回调（public：listener 结构需要函数指针）
    static void registryGlobalImpl(void *data, wl_registry *reg, uint32_t name,
                                   const char *iface, uint32_t version);
    static void registryGlobalRemoveImpl(void *data, wl_registry *reg,
                                         uint32_t name);
    static void popupRectangle(void *data, zwp_input_popup_surface_v2 *popup,
                               int32_t x, int32_t y, int32_t w, int32_t h);
    // seat 级指针路由（niri 上 IM popup 不收指针事件，见 setClickHandler）
    static void seatCapabilities(void *data, wl_seat *seat, uint32_t caps);
    static void pointerEnter(void *data, wl_pointer *p, uint32_t serial,
                             wl_surface *surface, wl_fixed_t sx, wl_fixed_t sy);
    static void pointerLeave(void *data, wl_pointer *p, uint32_t serial,
                             wl_surface *surface);
    static void pointerMotion(void *data, wl_pointer *p, uint32_t time,
                              wl_fixed_t sx, wl_fixed_t sy);
    static void pointerButton(void *data, wl_pointer *p, uint32_t serial,
                              uint32_t time, uint32_t button, uint32_t state);

private:
    void onConnectionCreated(const std::string &name, wl_display *display);
    void setupDisplay(wl_display *display);
    bool ensurePopup(InputContext *ic); // IC 变化时重建 surface+popup
    void destroyPopupSurface();
    void teardown();

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
    zwp_input_method_v2 *im_ = nullptr; // 借用：waylandim 所有
    zwp_input_popup_surface_v2 *popup_ = nullptr;
    wl_surface *surface_ = nullptr;
    TrackableObjectReference<InputContext> icRef_; // popup 所属 IC

    // 指针路由状态
    bool hasCursorRect_ = false; // text_input_rectangle 是否已送达（决策门）
    bool pointerOnPopup_ = false; // 指针焦点在我们 popup 表面（直达模式）
    std::function<void(int row)> clickHandler_;
    std::function<void(int row)> hoverHandler_;
    int lastHoverRow_ = -1;
    int ptrX_ = -10000, ptrY_ = -10000; // 最近指针位置（焦点窗口局部）

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
