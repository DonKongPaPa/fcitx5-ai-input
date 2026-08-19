#define _GNU_SOURCE 1
#include "popup_surface.h"

#include "fcitx-wayland/zwp_input_method_v2.h"

#include <fcitx-utils/log.h>
#include <fcitx/addonmanager.h>
#include <fcitx/inputcontext.h>
#include <wayland_public.h>

#include <fcntl.h>

#include <cstring>
#include <sys/mman.h>
#include <unistd.h>

#include "wayland-input-method-unstable-v2-client-protocol.h"

namespace fcitx {

static constexpr int kDefaultWidth = 360;
static constexpr int kDefaultHeight = 200;

static const wl_registry_listener kRegistryListener = {
    /* .global = */ &VoicePopup::registryGlobalImpl,
    /* .global_remove = */ &VoicePopup::registryGlobalRemoveImpl,
};

static const zwp_input_popup_surface_v2_listener kPopupListener = {
    /* .text_input_rectangle = */ &VoicePopup::popupRectangle,
};

static const wl_seat_listener kSeatListener = {
    /* .capabilities = */ &VoicePopup::seatCapabilities,
    /* .name = */ // v4+ 会发 name 事件；listener 槽为 NULL 时 libwayland
    // 直接 abort（listener function for opcode 1 of wl_seat is NULL）
    [](void *, wl_seat *, const char *) {},
};

static const wl_pointer_listener kPointerListener = {
    /* .enter = */ &VoicePopup::pointerEnter,
    /* .leave = */ &VoicePopup::pointerLeave,
    /* .motion = */ &VoicePopup::pointerMotion,
    /* .button = */ &VoicePopup::pointerButton,
    /* .axis = */
    [](void *, wl_pointer *, uint32_t, uint32_t, wl_fixed_t) {},
    /* .frame = */ // listener 槽 NULL 时事件一到 libwayland 直接 abort
    [](void *, wl_pointer *) {},
    /* .axis_source = */
    [](void *, wl_pointer *, uint32_t) {},
    /* .axis_stop = */
    [](void *, wl_pointer *, uint32_t, uint32_t) {},
    /* .axis_discrete = */
    [](void *, wl_pointer *, uint32_t, int32_t) {},
};

// 合成器告知光标矩形（popup 定位锚点；窗口局部坐标，与 wl_pointer 事件同空间）
void VoicePopup::popupRectangle(void *data, zwp_input_popup_surface_v2 *,
                                int32_t x, int32_t y, int32_t w, int32_t h) {
    auto *s = static_cast<VoicePopup *>(data);
    s->cursorX_ = x;
    s->cursorY_ = y;
    s->cursorW_ = w;
    s->cursorH_ = h;
    s->hasCursorRect_ = true;
    FCITX_INFO() << "VoicePopup: text_input_rectangle " << x << "," << y << " "
                 << w << "x" << h << "（窗口局部）";
}

// ---------------------------------------------------------------------------
// P3 鼠标路由：seat 级 wl_pointer
// niri 的 contents_under 只命中窗口/层 surface 树，IM popup 收不到指针
// 事件——点击落到焦点窗口，我们在这里收窗口局部坐标做映射命中
// ---------------------------------------------------------------------------
void VoicePopup::seatCapabilities(void *data, wl_seat *seat, uint32_t caps) {
    auto *s = static_cast<VoicePopup *>(data);
    if ((caps & WL_SEAT_CAPABILITY_POINTER) && !s->pointer_) {
        s->pointer_ = wl_seat_get_pointer(seat);
        wl_pointer_add_listener(s->pointer_, &kPointerListener, s);
        FCITX_INFO() << "VoicePopup: seat pointer acquired（鼠标路由就绪）";
    } else if (!(caps & WL_SEAT_CAPABILITY_POINTER) && s->pointer_) {
        wl_pointer_release(s->pointer_);
        s->pointer_ = nullptr;
    }
}

void VoicePopup::pointerEnter(void *data, wl_pointer *, uint32_t,
                              wl_surface *surface, wl_fixed_t sx,
                              wl_fixed_t sy) {
    auto *s = static_cast<VoicePopup *>(data);
    s->ptrX_ = wl_fixed_to_int(sx);
    s->ptrY_ = wl_fixed_to_int(sy);
    if (surface == s->surface_) {
        // niri 实测：IM popup 收得到 pointer enter（同 classicui 机制），
        // 坐标即面板局部（含阴影余量）——直接转发给 Flutter 引擎，
        // hover/点击命中由 Dart 处理
        s->pointerOnPopup_ = true;
        if (s->pointerSink_) {
            s->pointerSink_(PointerEvent::Enter, s->ptrX_, s->ptrY_);
        }
    } else {
        s->pointerOnPopup_ = false;
    }
}

void VoicePopup::pointerLeave(void *data, wl_pointer *, uint32_t,
                              wl_surface *surface) {
    auto *s = static_cast<VoicePopup *>(data);
    if (surface == s->surface_) {
        s->pointerOnPopup_ = false;
        if (s->pointerSink_) {
            s->pointerSink_(PointerEvent::Leave, s->ptrX_, s->ptrY_);
        }
    }
    s->ptrX_ = -10000;
    s->ptrY_ = -10000;
}

void VoicePopup::pointerMotion(void *data, wl_pointer *, uint32_t,
                               wl_fixed_t sx, wl_fixed_t sy) {
    auto *s = static_cast<VoicePopup *>(data);
    s->ptrX_ = wl_fixed_to_int(sx);
    s->ptrY_ = wl_fixed_to_int(sy);
    if (s->pointerOnPopup_ && s->pointerSink_) {
        s->pointerSink_(PointerEvent::Motion, s->ptrX_, s->ptrY_);
    }
}

void VoicePopup::pointerButton(void *data, wl_pointer *, uint32_t,
                               uint32_t, uint32_t button, uint32_t state) {
    auto *s = static_cast<VoicePopup *>(data);
    if (button != 0x110 || !s->pointerOnPopup_) { // 只处理左键
        return;
    }
    if (s->pointerSink_) {
        s->pointerSink_(
            state == WL_POINTER_BUTTON_STATE_PRESSED ? PointerEvent::Press
                                                     : PointerEvent::Release,
            s->ptrX_, s->ptrY_);
    }
}

VoicePopup::VoicePopup(Instance *instance) : instance_(instance) {
    if (auto *wayland = instance_->addonManager().addon("wayland", true)) {
        connHandler_ = wayland->call<IWaylandModule::addConnectionCreatedCallback>(
            [this](const std::string &name, wl_display *display, FocusGroup *) {
                onConnectionCreated(name, display);
            });
        closeHandler_ = wayland->call<IWaylandModule::addConnectionClosedCallback>(
            [this](const std::string &, wl_display *) {
                // 连接已死：只清指针，不 destroy（对象已随 display 失效）
                std::lock_guard<std::mutex> lock(mutex_);
                surface_ = nullptr;
                surfaceCompat_ = nullptr;
                popup_ = nullptr;
                im_ = nullptr;
                pool_ = nullptr;
                for (auto &b : buffers_) {
                    b = nullptr;
                }
                pixels_ = nullptr;
                compositor_ = nullptr;
                shm_ = nullptr;
                seat_ = nullptr;
                pointer_ = nullptr;
                hasCursorRect_ = false;
                display_ = nullptr;
            });
        FCITX_INFO() << "VoicePopup: wayland connection watcher registered";
    } else {
        FCITX_WARN() << "VoicePopup: wayland module unavailable";
    }
}

VoicePopup::~VoicePopup() { teardown(); }

bool VoicePopup::ready() { return pool_ && buffers_[0]; }

void VoicePopup::onConnectionCreated(const std::string &name,
                                     wl_display *display) {
    // waylandim 的连接名形如 "wayland:<display>"；只有存在
    // zwp_input_method_manager_v2 的连接才是输入法连接，registry 回调里判断
    std::lock_guard<std::mutex> lock(mutex_);
    if (display_) {
        return; // 已绑定一个连接
    }
    FCITX_INFO() << "VoicePopup: new wayland connection " << name;
    setupDisplay(display);
}

void VoicePopup::setupDisplay(wl_display *display) {
    display_ = display;
    registry_ = wl_display_get_registry(display_);
    wl_registry_add_listener(registry_, &kRegistryListener, this);
    wl_display_flush(display_);
}

void VoicePopup::registryGlobalImpl(void *data, wl_registry *reg, uint32_t name,
                                const char *iface, uint32_t version) {
    auto *self = static_cast<VoicePopup *>(data);
    std::lock_guard<std::mutex> lock(self->mutex_);

    if (strcmp(iface, "wl_compositor") == 0 && !self->compositor_) {
        // damage_buffer 需要 wl_surface ≥ v4；请求 min(版本,4)
        uint32_t v = version < 4 ? version : 4;
        self->compositorVersion_ = v;
        self->compositor_ = static_cast<wl_compositor *>(wl_registry_bind(
            reg, name, &wl_compositor_interface, v));
    } else if (strcmp(iface, "wl_shm") == 0 && !self->shm_) {
        self->shm_ = static_cast<wl_shm *>(
            wl_registry_bind(reg, name, &wl_shm_interface, 1));
    } else if (strcmp(iface, "wl_seat") == 0 && !self->seat_) {
        // P3 鼠标路由：seat 级 wl_pointer。绑 v3（capabilities 即止）——
        // v5+ 的 frame 事件若 listener 槽缺失会 abort（已补 no-op 双保险）
        uint32_t sv = version < 3 ? version : 3;
        self->seat_ = static_cast<wl_seat *>(wl_registry_bind(
            reg, name, &wl_seat_interface, sv));
        wl_seat_add_listener(self->seat_, &kSeatListener, self);
    } else if (strcmp(iface, "zwp_input_method_manager_v2") == 0) {
        // 仅作为"这是 waylandim 的 IM 连接"的判据；不绑定第二个 IM
        // （协议规定一个 seat 只允许一个 input method，waylandim 已 bind）
        self->isImConnection_ = true;
    }

    // compositor+shm 齐备（且确为 IM 连接）→ 建 shm 池；surface/popup 延迟到
    // ensurePopup（需要 IC 才能从 waylandim 取 IM proxy）
    if (self->isImConnection_ && self->compositor_ && self->shm_ &&
        !self->pool_) {
        self->width_ = kDefaultWidth;
        self->height_ = kDefaultHeight;
        size_t stride = self->width_ * 4;
        size_t bufSize = stride * self->height_;
        size_t poolSize = bufSize * 2;
        self->poolFd_ =
            memfd_create("vi-popup", MFD_CLOEXEC);
        ftruncate(self->poolFd_, poolSize);
        self->pixels_ = static_cast<uint8_t *>(
            mmap(nullptr, poolSize, PROT_READ | PROT_WRITE, MAP_SHARED,
                 self->poolFd_, 0));
        self->pool_ = wl_shm_create_pool(self->shm_, self->poolFd_, poolSize);
        for (int i = 0; i < 2; ++i) {
            self->buffers_[i] = wl_shm_pool_create_buffer(
                self->pool_, i * bufSize, self->width_, self->height_, stride,
                WL_SHM_FORMAT_ARGB8888);
        }
        FCITX_INFO() << "VoicePopup: shm pool ready ("
                     << self->width_ << "x" << self->height_ << " dbl)";
        wl_display_flush(self->display_);
    }
}

void VoicePopup::registryGlobalRemoveImpl(void *data, wl_registry *, uint32_t) {
    // F3 简化：全局移除不处理（连接关闭走 teardown）
    (void)data;
}

bool VoicePopup::ensurePopup(InputContext *ic) {
    if (!pool_ || !compositor_) {
        return false;
    }
    if (popup_ && surface_ && icRef_.get() == ic) {
        return true; // 同一 IC 复用
    }
    destroyPopupSurface();

    auto *waylandim = instance_->addonManager().addon("waylandim", true);
    if (!waylandim) {
        FCITX_WARN() << "VoicePopup: waylandim addon unavailable";
        return false;
    }
    auto *imWrapper =
        waylandim->call<IWaylandIMModule::getInputMethodV2>(ic);
    im_ = wayland::rawPointer(imWrapper); // 借用，归 waylandim 所有
    if (!im_) {
        // frontendName() 是 5.1 API（bookworm 5.0.21 没有）：对非 wayland_v2
        // 前端的 IC，getInputMethodV2 本身就返回 null，无需前端名判断
        FCITX_INFO() << "VoicePopup: IC 无 waylandim IM proxy（非 wayland_v2 前端？）";
        return false;
    }

    surface_ = wl_compositor_create_surface(compositor_);
    // fcitx wayland C++ wrapper 兼容层（宿主机崩溃修复）：classicui 等
    // 组件的 wl_pointer enter thunk 会把 wl_surface 的 user_data 直接
    // reinterpret 成 fcitx::wayland::WlSurface* 再读 userData_（+0x48）。
    // 裸 C API 创建的 proxy user_data=NULL → 经典 UI 解引用 NULL 直接
    // SIGSEGV（实测：鼠标进入本 popup 必崩）。挂一块与 WlSurface 布局
    // 等大的零填充占位：userData_ 偏移处为 0 → 对方的 if(!window) return
    // 路径安全返回。字段只读这一个偏移，其余不参与跨组件调用。
    surfaceCompat_ = calloc(1, 0x58);
    wl_proxy_set_user_data(reinterpret_cast<wl_proxy *>(surface_),
                            surfaceCompat_);
    popup_ = zwp_input_method_v2_get_input_popup_surface(im_, surface_);
    zwp_input_popup_surface_v2_add_listener(popup_, &kPopupListener, this);
    icRef_ = ic->watch();
    FCITX_INFO() << "VoicePopup: popup surface attached to waylandim IM";
    wl_display_flush(display_);
    return true;
}

void VoicePopup::destroyPopupSurface() {
    if (popup_) {
        zwp_input_popup_surface_v2_destroy(popup_);
        popup_ = nullptr;
    }
    if (surface_) {
        wl_surface_destroy(surface_);
        surface_ = nullptr;
    }
    if (surfaceCompat_) {
        free(surfaceCompat_);
        surfaceCompat_ = nullptr;
    }
}

// —— 帧绘制（F3：色块；F4 由 pushFrame 替代）——
// damage_buffer 需 wl_surface ≥4，旧合成器回退 wl_damage
static void damageSurface(wl_surface *s, uint32_t ver, int w, int h) {
    if (ver >= 4) {
        wl_surface_damage_buffer(s, 0, 0, w, h);
    } else {
        wl_surface_damage(s, 0, 0, w, h);
    }
}

static void paintTestPattern(uint8_t *argb, int w, int h) {
    for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w; ++x) {
            uint8_t *p = argb + (y * w + x) * 4;
            // MD3 primary 紫色调 + 底部 1/4 强调色，预乘 alpha=0.92
            p[3] = 235;
            if (y < h * 3 / 4) {
                p[2] = 103; // R
                p[1] = 80;  // G
                p[0] = 164; // B
            } else {
                p[2] = 0xF6; p[1] = 0x75; p[0] = 0xAB; // 二级容器色
            }
        }
    }
}

void VoicePopup::prepare(InputContext *ic) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!ensurePopup(ic)) {
        return;
    }
    // 全透明首帧：触发 map 流水线（内容仍不可见）
    size_t bufSize = static_cast<size_t>(width_) * height_ * 4;
    uint8_t *dst = pixels_ + cur_ * bufSize;
    memset(dst, 0, bufSize);
    wl_surface_attach(surface_, buffers_[cur_], 0, 0);
    damageSurface(surface_, compositorVersion_, width_, height_);
    wl_surface_commit(surface_);
    cur_ = 1 - cur_;
    wl_display_flush(display_);
}

void VoicePopup::show(InputContext *ic) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!ensurePopup(ic)) {
        FCITX_WARN() << "VoicePopup::show but popup not ready";
        return;
    }
    if (patternMode_) {
        size_t bufSize = width_ * height_ * 4;
        uint8_t *dst = pixels_ + cur_ * bufSize;
        paintTestPattern(dst, width_, height_);
        wl_surface_attach(surface_, buffers_[cur_], 0, 0);
        damageSurface(surface_, compositorVersion_, width_, height_);
        wl_surface_commit(surface_);
        cur_ = 1 - cur_;
        wl_display_flush(display_);
    }
    // flutter 模式：不主动 commit，等 UiBridge 首帧（无 buffer 不 map）
    visible_ = true;
}

void VoicePopup::hide() {
    std::lock_guard<std::mutex> lock(mutex_);
    // 不销毁 surface：销毁不产生 damage，niri 会残留旧画面数秒；
    // 提交全透明帧用自己的 damage 立即清掉内容，popup 保留复用（已预热）
    if (surface_ && buffers_[0]) {
        size_t bufSize = static_cast<size_t>(width_) * height_ * 4;
        memset(pixels_ + cur_ * bufSize, 0, bufSize);
        wl_surface_attach(surface_, buffers_[cur_], 0, 0);
        damageSurface(surface_, compositorVersion_, width_, height_);
        wl_surface_commit(surface_);
        cur_ = 1 - cur_;
    }
    visible_ = false;
    if (display_) {
        wl_display_flush(display_);
    }
}

// 重建 shm 池（帧尺寸变化时）；surface/popup 不动
void VoicePopup::resize(int w, int h) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!pool_ || (w == width_ && h == height_)) {
        return;
    }
    for (auto &b : buffers_) {
        if (b) {
            wl_buffer_destroy(b);
            b = nullptr;
        }
    }
    wl_shm_pool_destroy(pool_);
    munmap(pixels_, static_cast<size_t>(width_) * height_ * 4 * 2);
    close(poolFd_);

    width_ = w;
    height_ = h;
    size_t stride = static_cast<size_t>(w) * 4;
    size_t bufSize = stride * h;
    size_t poolSize = bufSize * 2;
    poolFd_ = memfd_create("vi-popup", MFD_CLOEXEC);
    ftruncate(poolFd_, poolSize);
    pixels_ = static_cast<uint8_t *>(
        mmap(nullptr, poolSize, PROT_READ | PROT_WRITE, MAP_SHARED, poolFd_, 0));
    pool_ = wl_shm_create_pool(shm_, poolFd_, poolSize);
    for (int i = 0; i < 2; ++i) {
        buffers_[i] = wl_shm_pool_create_buffer(
            pool_, i * bufSize, w, h, stride, WL_SHM_FORMAT_ARGB8888);
    }
    cur_ = 0;
    FCITX_INFO() << "VoicePopup: shm pool resized to " << w << "x" << h;
}

void VoicePopup::pushFrameBGRA(const uint8_t *bgra, int w, int h) {
    if (w != width_ || h != height_) {
        resize(w, h);
    }
    std::lock_guard<std::mutex> lock(mutex_);
    // 隐藏后丢弃迟到帧（hide 已提交透明帧，idle 态的帧会把它覆盖回来）
    if (!visible_ || !surface_ || !buffers_[0] || !popup_) {
        return;
    }
    size_t bufSize = static_cast<size_t>(width_) * height_ * 4;
    // 引擎软渲输出即 wl_shm ARGB8888 小端字节序（BGRA），直接 memcpy
    memcpy(pixels_ + cur_ * bufSize, bgra, bufSize);
    wl_surface_attach(surface_, buffers_[cur_], 0, 0);
    damageSurface(surface_, compositorVersion_, width_, height_);
    wl_surface_commit(surface_);
    cur_ = 1 - cur_;
    visible_ = true;
    wl_display_flush(display_);
}

void VoicePopup::teardown() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!display_) {
        return;
    }
    destroyPopupSurface();
    im_ = nullptr; // 借自 waylandim，不 destroy
    for (auto &b : buffers_) {
        if (b) {
            wl_buffer_destroy(b);
        }
    }
    if (pool_) {
        wl_shm_pool_destroy(pool_);
    }
    if (pixels_) {
        munmap(pixels_, width_ * height_ * 4 * 2);
    }
    if (poolFd_ >= 0) {
        close(poolFd_);
    }
    pool_ = nullptr;
    pixels_ = nullptr;
    display_ = nullptr;
}

} // namespace fcitx
