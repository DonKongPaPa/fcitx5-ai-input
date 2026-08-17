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

// 合成器告知光标矩形（popup 定位锚点）
void VoicePopup::popupRectangle(void *data, zwp_input_popup_surface_v2 *,
                                int32_t x, int32_t y, int32_t w, int32_t h) {
    auto *s = static_cast<VoicePopup *>(data);
    s->cursorX_ = x;
    s->cursorY_ = y;
    s->cursorW_ = w;
    s->cursorH_ = h;
    FCITX_INFO() << "VoicePopup: text_input_rectangle " << x << "," << y << " "
                 << w << "x" << h;
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
                popup_ = nullptr;
                im_ = nullptr;
                pool_ = nullptr;
                for (auto &b : buffers_) {
                    b = nullptr;
                }
                pixels_ = nullptr;
                compositor_ = nullptr;
                shm_ = nullptr;
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

    if (!ic || ic->frontendName() != "wayland_v2") {
        FCITX_INFO() << "VoicePopup: ic frontend="
                     << (ic ? ic->frontendName() : std::string("null"))
                     << "（需要 wayland_v2 才能取 IM proxy）";
        return false;
    }
    auto *waylandim = instance_->addonManager().addon("waylandim", true);
    if (!waylandim) {
        FCITX_WARN() << "VoicePopup: waylandim addon unavailable";
        return false;
    }
    auto *imWrapper =
        waylandim->call<IWaylandIMModule::getInputMethodV2>(ic);
    im_ = wayland::rawPointer(imWrapper); // 借用，归 waylandim 所有
    if (!im_) {
        FCITX_WARN() << "VoicePopup: waylandim has no InputMethodV2 for ic";
        return false;
    }

    surface_ = wl_compositor_create_surface(compositor_);
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

void VoicePopup::show(InputContext *ic) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!ensurePopup(ic)) {
        FCITX_WARN() << "VoicePopup::show but popup not ready";
        return;
    }
    size_t bufSize = width_ * height_ * 4;
    uint8_t *dst = pixels_ + cur_ * bufSize;
    paintTestPattern(dst, width_, height_);
    wl_surface_attach(surface_, buffers_[cur_], 0, 0);
    damageSurface(surface_, compositorVersion_, width_, height_);
    wl_surface_commit(surface_);
    cur_ = 1 - cur_;
    visible_ = true;
    wl_display_flush(display_);
}

void VoicePopup::hide() {
    std::lock_guard<std::mutex> lock(mutex_);
    // 照抄 classicui：隐藏即销毁 popup+surface（pool 复用）
    destroyPopupSurface();
    im_ = nullptr;
    icRef_ = {};
    visible_ = false;
    if (display_) {
        wl_display_flush(display_);
    }
}

void VoicePopup::pushFrame(const uint8_t *rgba, int w, int h) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!surface_ || !buffers_[0] || !popup_) {
        return;
    }
    // F4：尺寸变化时暂不重建（Flutter 侧固定逻辑分辨率），仅拷贝
    if (w != width_ || h != height_) {
        FCITX_WARN() << "VoicePopup: frame size mismatch " << w << "x" << h
                     << " != " << width_ << "x" << height_;
        return;
    }
    size_t bufSize = width_ * height_ * 4;
    uint8_t *dst = pixels_ + cur_ * bufSize;
    // RGBA→BGRA（WL_SHM_FORMAT_ARGB8888 小端即 BGRA 字节序）
    for (int i = 0; i < w * h; ++i) {
        dst[i * 4 + 0] = rgba[i * 4 + 2];
        dst[i * 4 + 1] = rgba[i * 4 + 1];
        dst[i * 4 + 2] = rgba[i * 4 + 0];
        dst[i * 4 + 3] = rgba[i * 4 + 3];
    }
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
