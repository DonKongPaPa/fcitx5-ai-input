#ifndef _FCITX5_VOICEINPUT_POPUP_SURFACE_H_
#define _FCITX5_VOICEINPUT_POPUP_SURFACE_H_

#include <fcitx/instance.h>
#include <fcitx-utils/trackableobject.h>
#include <wayland_public.h>

#include <memory>
#include <mutex>

struct wl_display;
struct wl_registry;
struct wl_compositor;
struct wl_shm;
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

    // wayland C 回调（public：listener 结构需要函数指针）
    static void registryGlobalImpl(void *data, wl_registry *reg, uint32_t name,
                                   const char *iface, uint32_t version);
    static void registryGlobalRemoveImpl(void *data, wl_registry *reg,
                                         uint32_t name);
    static void popupRectangle(void *data, zwp_input_popup_surface_v2 *popup,
                               int32_t x, int32_t y, int32_t w, int32_t h);

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
    zwp_input_method_v2 *im_ = nullptr; // 借用：waylandim 所有
    zwp_input_popup_surface_v2 *popup_ = nullptr;
    wl_surface *surface_ = nullptr;
    TrackableObjectReference<InputContext> icRef_; // popup 所属 IC

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
