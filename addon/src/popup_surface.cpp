#define _GNU_SOURCE 1
#include "popup_surface.h"

#include "wlr-layer-shell-client-protocol.h"

// wlr-layer-shell 的 get_popup 请求参数引用 xdg_popup_interface，生成的
// private-code 会 extern 它；本模块从不调用 get_popup（layer 卡片无子
// popup），零定义仅为满足链接
extern "C" const wl_interface xdg_popup_interface = {};

// cursor-shape-v1 的 private-code 引用 tablet-unstable-v2 的接口符号
//（平板光标路径）；本模块只用 pointer 的 set_shape，零定义满足链接
extern "C" const wl_interface zwp_tablet_tool_v2_interface = {};

#include "fcitx-wayland/zwp_input_method_v2.h"

#include <fcitx-utils/log.h>
#include <fcitx/addonmanager.h>
#include <fcitx/inputcontext.h>
#include <fcitx/inputpanel.h>
#include <fcitx-utils/event.h>
#include <fcitx/text.h>
#include <wayland_public.h>

#include <fcntl.h>

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cstring>
#include <sstream>
#include <sys/mman.h>
#include <unistd.h>

#include "wayland-input-method-unstable-v2-client-protocol.h"
#include "viewporter-client-protocol.h"
#include "cursor-shape-v1-client-protocol.h"
#include "fractional-scale-v1-client-protocol.h"

namespace fcitx {

static uint64_t nowUsSafe() {
    return std::chrono::duration_cast<std::chrono::microseconds>(
               std::chrono::steady_clock::now().time_since_epoch())
        .count();
}

static constexpr int kDefaultWidth = 360;
static constexpr int kDefaultHeight = 200;

static const wl_registry_listener kRegistryListener = {
    /* .global = */ &VoicePopup::registryGlobalImpl,
    /* .global_remove = */ &VoicePopup::registryGlobalRemoveImpl,
};

static const wl_output_listener kOutputListener = {
    /* .geometry = */ &VoicePopup::outputGeometry,
    /* .mode = */ &VoicePopup::outputMode,
    /* .done = */ &VoicePopup::outputDone,
    /* .scale = */ &VoicePopup::outputScale,
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

static const wp_fractional_scale_v1_listener kFscaleListener = {
    /* .preferred_scale = */ &VoicePopup::preferredScale,
};

static const zwlr_layer_surface_v1_listener kLayerListener = {
    /* .configure = */ &VoicePopup::layerConfigure,
    /* .closed = */
    [](void *, zwlr_layer_surface_v1 *) {},
};

// layer-shell 首个 configure 到达：ack 后才允许提交 buffer（协议要求）
void VoicePopup::layerConfigure(void *data, zwlr_layer_surface_v1 *ls,
                                uint32_t serial, uint32_t w, uint32_t h) {
    auto *s = static_cast<VoicePopup *>(data);
    std::lock_guard<std::mutex> lock(s->mutex_);
    zwlr_layer_surface_v1_ack_configure(ls, serial);
    if (!s->layerConfigured_) {
        s->layerConfigured_ = true;
        FCITX_INFO() << "VoicePopup: layer surface configured " << w << "x"
                     << h << "（" << (s->anchorBottom_ ? "底部" : "顶部")
                     << "居中就绪）";
    }
}

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
    // chromium 系恒 0,0 0x0；GTK/Qt 上报真实值。auto 模式的回退判据
    if (x != 0 || y != 0 || w != 0 || h != 0) {
        if (!s->sawRealRect_) {
            FCITX_INFO() << "VoicePopup: 收到真实光标矩形（本 IC 支持跟随）";
        }
        s->sawRealRect_ = true;
        s->probeTimer_.reset(); // 矩形已到：跟随成立，无需切 layer
        if (s->decisionPending_) {
            s->decisionPending_ = false; // 解除挂起，帧放开
            if (s->modeSwitchHandler_) {
                s->modeSwitchHandler_(); // 引擎补推一帧
            }
        }
        // 应用级知识：重聚焦若换新 IC（Electron 会话级 text-input），
        // 凭程序名直接跟随，首下不再回退
        if (!s->lastProgram_.empty()) {
            s->followingApps_.insert(s->lastProgram_);
        }
        if (s->preeditProbeActive_) {
            // 不撤：preedit 是录音指示器+跟随锚点（partial 会持续灌入）
            FCITX_INFO() << "VoicePopup: 探针奏效——矩形已按当前光标重报";
        }
    }
    FCITX_INFO() << "VoicePopup: text_input_rectangle " << x << "," << y << " "
                 << w << "x" << h << "（窗口局部）";
}

// ---------------------------------------------------------------------------
// 鼠标路由：seat 级 wl_pointer
// niri 的 contents_under 只命中窗口/层 surface 树，IM popup 收不到指针
// 事件——点击落到焦点窗口，我们在这里收窗口局部坐标做映射命中
// ---------------------------------------------------------------------------
void VoicePopup::seatCapabilities(void *data, wl_seat *seat, uint32_t caps) {
    auto *s = static_cast<VoicePopup *>(data);
    if ((caps & WL_SEAT_CAPABILITY_POINTER) && !s->pointer_) {
        s->pointer_ = wl_seat_get_pointer(seat);
        wl_pointer_add_listener(s->pointer_, &kPointerListener, s);
        if (s->cursorShapeMgr_ && !s->cursorShapeDev_) {
            s->cursorShapeDev_ = wp_cursor_shape_manager_v1_get_pointer(
                s->cursorShapeMgr_, s->pointer_);
        }
        FCITX_INFO() << "VoicePopup: seat pointer acquired（鼠标路由就绪）";
    } else if (!(caps & WL_SEAT_CAPABILITY_POINTER) && s->pointer_) {
        if (s->cursorShapeDev_) {
            wp_cursor_shape_device_v1_destroy(s->cursorShapeDev_);
            s->cursorShapeDev_ = nullptr;
        }
        wl_pointer_release(s->pointer_);
        s->pointer_ = nullptr;
    }
}

// 合成器告知真实缩放（1/120 单位；如 150=1.25）——重算物理池并通知上层
void VoicePopup::preferredScale(void *data, wp_fractional_scale_v1 *,
                                uint32_t scale) {
    auto *s = static_cast<VoicePopup *>(data);
    std::lock_guard<std::mutex> lock(s->mutex_);
    s->gotFscale_ = true;
    if (scale != 0) {
        s->lastFscaleNum_ = scale; // 跨 surface 记忆（layer 无 fractional 时兜底）
    }
    if (scale == s->scaleNum_ || scale == 0) {
        return;
    }
    s->scaleNum_ = scale;
    FCITX_INFO() << "VoicePopup: fractional scale → " << (scale / 120.0);
    if (s->logicalW_ > 0 && s->viewport_) {
        // 物理池按新 scale 重建；viewport destination 不在此急切下发——
        // 需与匹配尺寸的 buffer 同一 commit（见 syncViewport 注释）
        double sc = s->scale();
        int pw = static_cast<int>(s->logicalW_ * sc + 0.5);
        int ph = static_cast<int>(s->logicalH_ * sc + 0.5);
        s->resizeLocked(pw, ph);
    }
    if (s->scaleHandler_) {
        s->scaleHandler_(s->scaleNum_ / 120.0); // 出锁后调用更稳，这里同线程
    }
}

void VoicePopup::outputGeometry(void *, wl_output *, int32_t, int32_t,
                                int32_t, int32_t, int32_t, const char *,
                                const char *, int32_t) {}
void VoicePopup::outputMode(void *data, wl_output *, uint32_t, int32_t w,
                            int32_t h, int32_t) {
    // overlay 贴光标定位的钳制需要输出逻辑尺寸（物理 mode/scale）
    auto *s = static_cast<VoicePopup *>(data);
    std::lock_guard<std::mutex> lock(s->mutex_);
    s->outputPhysW_ = w;
    s->outputPhysH_ = h;
}
void VoicePopup::outputDone(void *, wl_output *) {}
void VoicePopup::outputScale(void *data, wl_output *, int32_t factor) {
    auto *s = static_cast<VoicePopup *>(data);
    std::lock_guard<std::mutex> lock(s->mutex_);
    if (factor != s->outputScale_ && !s->gotFscale_) {
        s->outputScale_ = factor;
        FCITX_INFO() << "VoicePopup: wl_output scale → " << factor;
        if (s->logicalW_ > 0 && s->viewport_) {
            int pw = s->logicalW_ * factor, ph = s->logicalH_ * factor;
            s->resizeLocked(pw, ph);
        }
        if (s->scaleHandler_) {
            s->scaleHandler_(s->scale());
        }
    } else if (factor != s->outputScale_) {
        s->outputScale_ = factor; // fractional 优先，仅记录
    }
}

void VoicePopup::pointerEnter(void *data, wl_pointer *, uint32_t serial,
                              wl_surface *surface, wl_fixed_t sx,
                              wl_fixed_t sy) {
    auto *s = static_cast<VoicePopup *>(data);
    s->ptrX_ = wl_fixed_to_int(sx);
    s->ptrY_ = wl_fixed_to_int(sy);
    FCITX_INFO() << "VoicePopup: pointer enter surface=" << surface
                 << "（ours=" << s->surface_ << "）at "
                 << s->ptrX_ << "," << s->ptrY_
                 << (surface == s->surface_ ? " [命中]" : " [非本卡片]");
    if (surface == s->surface_) {
        // niri：IM popup 收得到 pointer enter（同 classicui 机制），坐标即
        // 面板局部（含阴影余量）——直接转发给 Flutter 引擎，hover/点击
        // 命中由 Dart 处理
        if (s->cursorShapeDev_) {
            // 本表面的 enter：不设光标合成器即隐藏指针（协议把光标交给
            // 获得指针焦点的客户端）；raw embedder 无光标主题，用
            // cursor-shape 的 DEFAULT 形状即可
            wp_cursor_shape_device_v1_set_shape(
                s->cursorShapeDev_, serial,
                WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_DEFAULT);
        }
        s->pointerOnPopup_ = true;
        s->motionLogLeft_ = 5; // 诊断：每次命中后采样前几笔 motion
        FCITX_INFO() << "VoicePopup: [diag] enter 命中 " << s->ptrX_ << ","
                     << s->ptrY_;
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
    FCITX_INFO() << "VoicePopup: [diag] leave"
                 << (surface == s->surface_ ? "（本卡片）" : "（非本卡）");
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
    if (s->motionLogLeft_ > 0) {
        s->motionLogLeft_--;
        FCITX_INFO() << "VoicePopup: [diag] motion " << s->ptrX_ << ","
                     << s->ptrY_
                     << (s->pointerOnPopup_ ? " [命中]" : " [非命中]");
    }
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

// wayland 模块监听注册（可重试）：addon 加载顺序不保证 wayland 先于本
// 模块——构造时拿不到就在 prepare()（首个焦点事件，彼时全部 addon 已
// 加载）再试。注意必须在不持 mutex_ 的上下文调用：对已建立的连接，
// 注册回调会立即同步触发 onConnectionCreated（它自己要拿锁）
void VoicePopup::ensureWaylandWatcher() {
    if (connHandler_) {
        return;
    }
    auto *wayland = instance_->addonManager().addon("wayland", true);
    if (!wayland) {
        return; // 仍未加载，下次 prepare 再试
    }
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
            viewport_ = nullptr;
            fscale_ = nullptr;
            popup_ = nullptr;
            im_ = nullptr;
            layerSurface_ = nullptr;
            layerShell_ = nullptr;
            layerConfigured_ = false;
            emptyRegion_ = nullptr;
            pool_ = nullptr;
            for (auto &b : buffers_) {
                b = nullptr;
            }
            pixels_ = nullptr;
            compositor_ = nullptr;
            shm_ = nullptr;
            seat_ = nullptr;
            pointer_ = nullptr;
            cursorShapeDev_ = nullptr;
            cursorShapeMgr_ = nullptr;
            output_ = nullptr;
            hasCursorRect_ = false;
            display_ = nullptr;
        });
    FCITX_INFO() << "VoicePopup: wayland connection watcher registered";
}

// 构造时 wayland 可能尚未加载（addon 加载顺序不保证）：1s 重试，30 次
// 仍不成功则放弃（prepare() 每次焦点事件的重试仍是兜底）。回调返回
// false 即源自动移除——不要在回调内 reset 自身源（破坏分发）
void VoicePopup::scheduleWatcherRetry() {
    watcherRetry_ = instance_->eventLoop().addTimeEvent(
        CLOCK_MONOTONIC, nowUsSafe() + 1'000'000ull, 0,
        [this](EventSourceTime *, uint64_t) {
            ensureWaylandWatcher();
            return connHandler_ == nullptr && ++watcherTries_ < 30;
        });
}

VoicePopup::VoicePopup(Instance *instance) : instance_(instance) {
    ensureWaylandWatcher();
    if (!connHandler_) {
        scheduleWatcherRetry();
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
        // 鼠标路由：seat 级 wl_pointer。绑 v3（capabilities 即止）——
        // v5+ 的 frame 事件若 listener 槽缺失会 abort（已补 no-op 双保险）
        uint32_t sv = version < 3 ? version : 3;
        self->seat_ = static_cast<wl_seat *>(wl_registry_bind(
            reg, name, &wl_seat_interface, sv));
        wl_seat_add_listener(self->seat_, &kSeatListener, self);
    } else if (strcmp(iface, "wl_output") == 0 && !self->output_) {
        // wl_output 整数 scale 兜底（niri 不给 IM popup 发 fractional）
        self->output_ = static_cast<wl_output *>(wl_registry_bind(
            reg, name, &wl_output_interface, 2)); // v2 起 scale/done 事件
        wl_output_add_listener(self->output_, &kOutputListener, self);
        FCITX_INFO() << "VoicePopup: wl_output bound v2 name=" << name;
    } else if (strcmp(iface, "wp_viewporter") == 0 && !self->viewporter_) {
        FCITX_INFO() << "VoicePopup: global wp_viewporter v" << version;
        self->viewporter_ = static_cast<wp_viewporter *>(wl_registry_bind(
            reg, name, &wp_viewporter_interface, 1));
    } else if (strcmp(iface, "wp_fractional_scale_manager_v1") == 0 &&
               !self->fsManager_) {
        FCITX_INFO() << "VoicePopup: global wp_fractional_scale_manager_v1 v"
                     << version;
        self->fsManager_ =
            static_cast<wp_fractional_scale_manager_v1 *>(wl_registry_bind(
                reg, name, &wp_fractional_scale_manager_v1_interface, 1));
    } else if (strcmp(iface, "wp_cursor_shape_manager_v1") == 0 &&
               !self->cursorShapeMgr_) {
        // 表面指针可见性：enter 后由客户端负责设光标——不设则合成器
        // 隐藏指针（卡片上方"没有鼠标指针"的根源）
        self->cursorShapeMgr_ = static_cast<wp_cursor_shape_manager_v1 *>(
            wl_registry_bind(reg, name, &wp_cursor_shape_manager_v1_interface,
                             1));
        if (self->pointer_) {
            self->cursorShapeDev_ = wp_cursor_shape_manager_v1_get_pointer(
                self->cursorShapeMgr_, self->pointer_);
        }
    } else if (strcmp(iface, "zwlr_layer_shell_v1") == 0 &&
               !self->layerShell_) {
        // chromium 系定位回退用；version ≤3（4 的 bottom/surface 扩展非必需）
        uint32_t lv = version < 3 ? version : 3;
        self->layerShell_ = static_cast<zwlr_layer_shell_v1 *>(
            wl_registry_bind(reg, name, &zwlr_layer_shell_v1_interface, lv));
        FCITX_INFO() << "VoicePopup: zwlr_layer_shell_v1 bound v" << lv;
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
        self->poolCapacity_ = poolSize + poolSize / 2 + (512 << 10);
        self->poolFd_ =
            memfd_create("vi-popup", MFD_CLOEXEC);
        ftruncate(self->poolFd_, self->poolCapacity_);
        self->pixels_ = static_cast<uint8_t *>(
            mmap(nullptr, self->poolCapacity_, PROT_READ | PROT_WRITE,
                 MAP_SHARED, self->poolFd_, 0));
        self->pool_ = wl_shm_create_pool(self->shm_, self->poolFd_,
                                         self->poolCapacity_);
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
    // 全局移除不处理（连接关闭走 teardown）
    (void)data;
}

std::string VoicePopup::toLower(std::string s) {
    for (auto &c : s) {
        c = static_cast<char>(::tolower(static_cast<unsigned char>(c)));
    }
    return s;
}

void VoicePopup::setPositionPolicy(const std::string &mode,
                                   const std::string &fallbackAppsCsv) {
    std::lock_guard<std::mutex> lock(mutex_);
    positionMode_ = mode.empty() ? "auto" : mode;
    fallbackApps_.clear();
    std::string cur;
    std::stringstream ss(toLower(fallbackAppsCsv));
    while (std::getline(ss, cur, ',')) {
        // 去首尾空白
        while (!cur.empty() && (cur.front() == ' ' || cur.front() == '\t')) {
            cur.erase(cur.begin());
        }
        while (!cur.empty() && (cur.back() == ' ' || cur.back() == '\t')) {
            cur.pop_back();
        }
        if (!cur.empty()) {
            fallbackApps_.push_back(cur);
        }
    }
}

void VoicePopup::notifyCommit() {
    std::lock_guard<std::mutex> lock(mutex_);
    endPreeditProbe();
    if (!committedInThisIC_) {
        FCITX_INFO() << "VoicePopup: 本 IC 已上屏 → handle 有新鲜光标矩形"
                        "可继承，auto 下轮跟随";
    }
    committedInThisIC_ = true;
    if (!lastProgram_.empty()) {
        followingApps_.insert(lastProgram_);
    }
}

// —— 预输入探针（classicui 拼音候选窗实时跟随的同款机制）——
// 组合文本变化逼应用按当前光标重报矩形 → 正被追踪（show 刚重建）的
// 我们被合成器实时挪位
void VoicePopup::beginPreeditProbe(InputContext *ic) {
    if (!ic || preeditProbeActive_) {
        return;
    }
    // 可见组合文本「语音输入中」逐字打出：每字一次组合变化=每字一次
    // 报文机会（一次性整串 set 只有一次组合变化，报文可有可无）。
    // preedit 永不入文、且全程恒为这五个字（流式/候选文本只在卡片里
    // 展示）——组合长度恒定，光标矩形不随识别进度行进，卡片稳定锚在
    // 开始位置。上屏时 commitString 按协议替换 preedit（自清洁）
    static const char *const kProbe = "\u8bed\u97f3\u8f93\u5165\u4e2d"; // 语音输入中
    Text preedit(std::string(kProbe, 3)); // 首字「语」
    ic->inputPanel().setClientPreedit(preedit);
    // updatePreedit 才会把 client preedit 推给应用（UpdatePreeditEvent →
    // waylandim）；updateUserInterface 只刷新 UI 插件、不送达应用
    ic->updatePreedit();
    preeditProbeActive_ = true;
    probeTypingIdx_ = 1;
    probeTypeTimer_.reset();
    typeProbeNext(ic);
    FCITX_INFO() << "VoicePopup: 预输入探针已置（可见组合文本，逼应用重报光标矩形）";
}

void VoicePopup::typeProbeNext(InputContext *ic) {
    static const char *const kProbe =
        "\u8bed\u97f3\u8f93\u5165\u4e2d"; // 语音输入中（每字 3 字节）
    if (!ic || !preeditProbeActive_ || probeTypingIdx_ >= 5) {
        probeTypeTimer_.reset();
        return;
    }
    if (probeTypeTimer_) {
        probeTypeTimer_.reset();
    }
    const int idx = probeTypingIdx_;
    probeTypeTimer_ = instance_->eventLoop().addTimeEvent(
        CLOCK_MONOTONIC, nowUsSafe() + 40'000ull, 0,
        [this, idx](EventSourceTime *, uint64_t) {
            std::lock_guard<std::mutex> lock(mutex_);
            probeTypeTimer_.reset();
            if (auto *ic2 = icRef_.get()) {
                // 矩形到也不停链：探针五个字打完（视觉完整性），
                // partial 在队列里等
                if (preeditProbeActive_ && probeTypingIdx_ == idx && idx < 5) {
                    probeTypingIdx_ = idx + 1;
                    std::string txt(std::string(kProbe, (idx + 1) * 3));
                    ic2->inputPanel().setClientPreedit(Text(txt));
                    ic2->updatePreedit(); // 每字一次组合变化=报文机会
                    typeProbeNext(ic2);
                }
            }
            return true;
        });
}

void VoicePopup::endPreeditProbe() {
    probeTypeTimer_.reset();
    if (!preeditProbeActive_) {
        return;
    }
    preeditProbeActive_ = false;
    probeTypingIdx_ = 5;
    if (auto *ic = icRef_.get()) {
        ic->inputPanel().setClientPreedit(Text());
        ic->updatePreedit();
    }
}

void VoicePopup::primePreedit(InputContext *ic) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!ic || sawRealRect_ || committedInThisIC_) {
        return;
    }
    if (!surface_ && !ensurePopup(ic, /*atShow=*/false)) {
        return; // 无处可挂（非 wayland 且无 layer-shell）
    }
    if (topMode_ && !overlayFallback_) {
        return; // policy/名单判成 layer：无需矩形
    }
    beginPreeditProbe(ic); // overlay 兜底（DBus 前端）为可见指示器而挂
}


// 判定挂起结算 → layer 底部（持锁，两个触发点共用：8s 保险丝、录音
// 结束——结果/候选卡片必须显示，不能再等矩形）
void VoicePopup::resolvePendingToLayerLocked() {
    if (auto *ic = icRef_.get()) {
        // probeDeferralUsed_ 已置位 → ensurePopup 不再暂缓，知识仍缺 →
        // 真实回退 layer
        ensurePopup(ic, /*atShow=*/true);
        // 新 surface 在创建时带空输入区（防遮挡），而 show() 的"恢复
        // 全量"早已跑过——不补的话 fallback 卡片鼠标点不进
        if (surface_) {
            wl_surface_set_input_region(surface_, nullptr);
            FCITX_INFO() << "VoicePopup: 输入区恢复全量（结算后的 surface）";
        }
        if (modeSwitchHandler_) {
            modeSwitchHandler_(); // 引擎重推 UI（新 surface）
        }
    }
}

void VoicePopup::resolvePendingToLayer() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!decisionPending_) {
        return;
    }
    decisionPending_ = false;
    probeTimer_.reset();
    if (!visible_ || topMode_ || sawRealRect_ || committedInThisIC_ ||
        !surface_) {
        return;
    }
    FCITX_INFO() << "VoicePopup: 判定挂起结算（录音结束仍无矩形）→ "
                    "layer 底部";
    resolvePendingToLayerLocked();
}

void VoicePopup::armProbeFallbackTimer() {
    const uint64_t deadlineUs =
        std::chrono::duration_cast<std::chrono::microseconds>(
            std::chrono::steady_clock::now().time_since_epoch())
            .count() +
        // 保险丝 8s：矩形到达延迟无上界，任何固定判定窗口都会误判。
        // 真正结算点=录音结束（结果/候选卡片必须显示）
        // resolvePendingToLayer；定时器只兜异常路径（结算事件丢失）
        8'000'000ull;
    probeTimer_ = instance_->eventLoop().addTimeEvent(
        CLOCK_MONOTONIC, deadlineUs, 0, [this](EventSourceTime *, uint64_t) {
            std::lock_guard<std::mutex> lock(mutex_);
            probeTimer_.reset();
            decisionPending_ = false;
            if (visible_ && !topMode_ && !sawRealRect_ &&
                !committedInThisIC_ && surface_) {
                FCITX_INFO() << "VoicePopup: 判定挂起结算（保险丝）→ "
                                "layer 底部";
                resolvePendingToLayerLocked();
            }
            return true;
        });
}

// 定位模式决策：policy × 应用名单 × 矩形上报能力。
// - chromium 系的 wayland text-input 恒报 0,0 0x0 → 合成器把 input popup
//   放到窗口左上角；此类应用改用 layer-shell（anchor 由 policy 决定，
//   默认底部居中——layer 角色的合成器定位在我们手里）
// - auto 对名单外应用动态判断：prepare 阶段（atShow=false）先建 popup
//   探测矩形；show 阶段（atShow=true）仍未见真实矩形 → 回退 layer。
//   （在 prepare 就判 !sawRealRect_ 会自锁：popup 都没建过，矩形永远
//   收不到）
// - DBus 前端 IC（QT_IM_MODULE=fcitx 的 Qt 应用/启动器）无 IM proxy，
//   跟随路径整体不可达——ensurePopup 无条件 overlay 层兜底，不进本函数
bool VoicePopup::wantTopMode(InputContext *ic, bool atShow) {
    lastDecisionWasKnowledgeFallback_ = false;
    anchorBottom_ = true; // "top" 之外全部底部居中
    if (positionMode_ == "top") {
        anchorBottom_ = false;
        return true;
    }
    if (positionMode_ == "bottom") {
        return true;
    }
    if (positionMode_ != "auto") {
        return false; // caret
    }
    const std::string prog = toLower(ic->program());
    for (const auto &frag : fallbackApps_) {
        if (!prog.empty() && prog.find(frag) != std::string::npos) {
            FCITX_INFO() << "VoicePopup: 应用「" << prog
                         << "」命中定位回退名单（" << frag
                         << "）→ layer 模式";
            return true;
        }
    }
    if (atShow && !sawRealRect_ && !committedInThisIC_) {
        if (!lastProgram_.empty() &&
            followingApps_.count(toLower(ic->program())) > 0) {
            return false; // 该应用跟随成功过：重聚焦新 IC 首下直接跟随
        }
        lastDecisionWasKnowledgeFallback_ = true;
        FCITX_INFO() << "VoicePopup: auto：本 IC 未见真实光标矩形且无上屏"
                        "历史（该应用首次会话）";
        return true;
    }
    return false;
}

bool VoicePopup::ensurePopup(InputContext *ic, bool atShow) {
    if (!pool_ || !compositor_) {
        return false;
    }
    const bool icChanged = icRef_.get() != ic;
    if (icChanged) {
        sawRealRect_ = false;      // 矩形上报能力按 IC 记账
        committedInThisIC_ = false; // 上屏历史同样按 IC
        probeDeferralUsed_ = false; // 新 IC 重新给一次二次探测
    }
    // IM proxy 可用性一次查清，贯穿本次决策。DBus 前端 IC（QT_IM_MODULE=
    // fcitx 的 Qt 应用/启动器，如 DMS）：按键/上屏/光标矩形全走 D-Bus，
    // 永远取不到 waylandim 的 IM proxy——input popup 跟随路径不可达，
    // 只能 layer 自定位（overlay 层：启动器面板自身在 top 层，TOP 卡片
    // 会被整块盖住）
    im_ = nullptr;
    bool imAvailable = false;
    if (auto *waylandim = instance_->addonManager().addon("waylandim", true)) {
        auto *imWrapper =
            waylandim->call<IWaylandIMModule::getInputMethodV2>(ic);
        im_ = wayland::rawPointer(imWrapper); // 借用，归 waylandim 所有
        imAvailable = im_ != nullptr;
    }
    const bool overlay = !imAvailable;
    const bool top = [&]() {
        const bool want = wantTopMode(ic, atShow);
        // 知识回退 + 非强制（policy/名单）+ IM proxy 可用：show 时刻先不
        // 落 layer——保持 popup 让探针的后续组合变化有机会拿到矩形
        //（首个组合常不出报文）；矩形到即跟随，录音结束仍无矩形由
        // 结算路径切 layer
        if (want && lastDecisionWasKnowledgeFallback_ && atShow &&
            !topMode_ && !probeDeferralUsed_ && imAvailable) {
            probeDeferralUsed_ = true; // 本会话只暂缓一次（定时器重入不暂缓）
            FCITX_INFO() << "VoicePopup: 知识回退暂缓——popup 模式"
                            "二次探测（矩形到则跟随，否则录音结束"
                            "结算底部）";
            return false;
        }
        if (overlay && !topMode_) {
            FCITX_INFO() << "VoicePopup: IC 无 waylandim IM proxy（DBus "
                            "前端？）→ overlay 层卡片兜底";
        }
        return want || overlay;
    }();
    // layer 模式同 IC 复用（layer 定位权在我们手里，不涉及槽位竞争）；
    // popup 模式每次都重建：smithay 的 input popup 追踪槽是单槽、
    // last-create-wins（classicui 每次显示都重建 popup 重夺槽位）——我们
    // 若长期持有旧 popup，classicui 一旦创建过自己的 popup，合成器就不再
    // 给我们重定位，卡片永远停在旧光标处
    const bool reuse = surface_ && !icChanged && topMode_ && topMode_ == top &&
                       overlayFallback_ == overlay;
    if (reuse) {
        return true;
    }
    lastProgram_ = toLower(ic->program());
    destroyPopupSurface();
    topMode_ = top;
    overlayFallback_ = overlay;

    surface_ = wl_compositor_create_surface(compositor_);
    // 透明/隐藏态的空输入区域：layer surface 的输入区与像素透明度无关，
    // 不显式清空会把"出现过的区域"变成不可见遮挡（挡住下方按钮）；
    // 可见时再恢复全量输入区（nullptr = 默认全量）
    if (!emptyRegion_ && compositor_) {
        emptyRegion_ = wl_compositor_create_region(compositor_);
    }
    if (emptyRegion_) {
        wl_surface_set_input_region(surface_, emptyRegion_);
    }
    // fcitx wayland C++ wrapper 兼容层：classicui 等组件的 wl_pointer
    // enter thunk 会把 wl_surface 的 user_data 直接 reinterpret 成
    // fcitx::wayland::WlSurface* 再读 userData_（+0x48）。裸 C API 创建
    // 的 proxy user_data=NULL → 经典 UI 解引用 NULL 即 SIGSEGV。挂一块
    // 与 WlSurface 布局等大的零填充占位：userData_ 偏移处为 0 → 对方的
    // if(!window) return 路径安全返回。字段只读这一个偏移，其余不参与
    // 跨组件调用。
    surfaceCompat_ = calloc(1, 0x58);
    wl_proxy_set_user_data(reinterpret_cast<wl_proxy *>(surface_),
                            surfaceCompat_);
    // viewport（物理 buffer → 逻辑显示）+ fractional scale（真实缩放值）
    if (viewporter_) {
        viewport_ = wp_viewporter_get_viewport(viewporter_, surface_);
        // 每个新 surface 的 viewport 必须立即设 destination：它只在 Dart
        // resize 消息里设（尺寸不变就不再发），切应用重建 surface 后
        // destination 缺失 → 物理缓冲按原尺寸显示（放大 scale 倍）+
        // 指针坐标落在物理空间全越界 → 候选框鼠标失灵
        if (logicalW_ > 0 && logicalH_ > 0) {
            wp_viewport_set_destination(viewport_, logicalW_, logicalH_);
        }
    }
    if (fsManager_) {
        fscale_ = wp_fractional_scale_manager_v1_get_fractional_scale(
            fsManager_, surface_);
        wp_fractional_scale_v1_add_listener(fscale_, &kFscaleListener, this);
    }
    if (topMode_) {
        // layer-shell：不依赖应用上报光标矩形，合成器按我们的
        // anchor/margin/size 摆放（默认底部居中；"top" 兼容旧值顶部居中）。
        // configure 到达前不提交 buffer。
        // registry global 是异步到达的——IC 早激活时可能尚未 bind，
        // roundtrip 等一轮再判
        if (!layerShell_ && display_) {
            wl_display_roundtrip(display_);
        }
        if (!layerShell_) {
            if (overlayFallback_) {
                // DBus IC + 无 layer-shell（非 wayland 会话）：无处可挂
                FCITX_WARN() << "VoicePopup: IM proxy 与 layer-shell 均不可"
                                "用，无法显示卡片";
                return false;
            }
            FCITX_WARN() << "VoicePopup: 合成器无 zwlr_layer_shell_v1，"
                            "回退光标跟随";
            topMode_ = false;
            return ensurePopup(ic);
        }
        layerConfigured_ = false;
        layerSurface_ = zwlr_layer_shell_v1_get_layer_surface(
            layerShell_, surface_, nullptr,
            overlayFallback_ ? ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY
                             : ZWLR_LAYER_SHELL_V1_LAYER_TOP,
            "input-method");
        zwlr_layer_surface_v1_add_listener(layerSurface_, &kLayerListener,
                                           this);
        if (overlayFallback_) {
            // classicui-X11 同款近似：DBus IC 的 cursorRect 是窗口局部
            // 坐标，全屏启动器（DMS）场景≈输出坐标——锚 TOP|LEFT+margin
            // 贴光标摆放，放不下翻上/钳内
            applyOverlayAnchorLocked(ic);
        } else {
            zwlr_layer_surface_v1_set_anchor(
                layerSurface_, anchorBottom_
                                   ? ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM
                                   : ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP);
            zwlr_layer_surface_v1_set_margin(
                layerSurface_, anchorBottom_ ? 0 : 16, 0,
                anchorBottom_ ? 16 : 0, 0);
        }
        zwlr_layer_surface_v1_set_exclusive_zone(layerSurface_, -1);
        zwlr_layer_surface_v1_set_keyboard_interactivity(
            layerSurface_,
            ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE);
        // set_size 收逻辑尺寸：width_/height_ 是物理池尺寸（scale=2 下
        // 720 物理>整屏 640 逻辑，会被合成器钳制）；Dart 尺寸未到前用
        // 逻辑默认值，到后由 setLogicalSize 持续跟进
        zwlr_layer_surface_v1_set_size(
            layerSurface_, logicalW_ > 0 ? logicalW_ : kDefaultWidth,
            logicalH_ > 0 ? logicalH_ : kDefaultHeight);
        wl_surface_commit(surface_); // 空 commit：请求首个 configure
        icRef_ = ic->watch();
        FCITX_INFO() << "VoicePopup: layer surface created（"
                     << (overlayFallback_
                             ? "overlay 贴光标"
                             : anchorBottom_ ? "底部" : "顶部")
                     << "居中模式）";
    } else {
        popup_ = zwp_input_method_v2_get_input_popup_surface(im_, surface_);
        zwp_input_popup_surface_v2_add_listener(popup_, &kPopupListener, this);
        icRef_ = ic->watch();
        // 首次之外的每次 attach 都是重建（hide 已销毁 / classicui 抢过槽）
        popupAttachCount_++;
        FCITX_INFO() << "VoicePopup: popup surface attached to waylandim IM"
                     << (popupAttachCount_ > 1
                             ? "（重建：重夺定位槽，取最新光标矩形）"
                             : "");
    }
    wl_display_flush(display_);
    return true;
}

void VoicePopup::destroyPopupSurface() {
    if (layerSurface_) {
        zwlr_layer_surface_v1_destroy(layerSurface_);
        layerSurface_ = nullptr;
        layerConfigured_ = false;
    }
    if (popup_) {
        zwp_input_popup_surface_v2_destroy(popup_);
        popup_ = nullptr;
    }
    // 派生对象随 surface 销毁：fractional scale 有 destroy 请求；viewport
    // 是 surface 生命周期绑定（无 destroy，置空即可）。悬空 proxy 会在
    // shutdown flush 时触发 SIGSEGV
    if (fscale_) {
        wp_fractional_scale_v1_destroy(fscale_);
        fscale_ = nullptr;
    }
    if (viewport_) {
        wp_viewport_destroy(viewport_);
        viewport_ = nullptr;
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

// —— 帧绘制（色块测试帧；Flutter 帧走 pushFrameBGRA）——
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
    // 先补注册（若构造时 wayland 未加载）：不得持锁——对已建立连接
    // 注册回调会立即同步触发 onConnectionCreated（它要拿锁）
    ensureWaylandWatcher();
    std::lock_guard<std::mutex> lock(mutex_);
    // 光标矩形诊断：fcitx 核心从前端（wayland text-input / XIM spot）汇总。
    // 不打 frontendName()——那是 5.1 API（bookworm 5.0.21 编不过）；前端
    // 判断走 getInputMethodV2 是否返回 null（见 ensurePopup）
    const auto &cr = ic->cursorRect();
    FCITX_INFO() << "VoicePopup: ic cursorRect " << cr.left() << ","
                 << cr.top() << " " << cr.width() << "x" << cr.height();
    if (!ensurePopup(ic, /*atShow=*/false)) {
        return;
    }
    // 全透明首帧：触发 map 流水线（内容仍不可见）。
    // layer 模式首个 configure 未到前不提交 buffer（协议要求）
    if (topMode_ && !layerConfigured_) {
        wl_display_flush(display_);
        return;
    }
    size_t bufSize = static_cast<size_t>(width_) * height_ * 4;
    uint8_t *dst = pixels_ + cur_ * bufSize;
    memset(dst, 0, bufSize);
    wl_surface_attach(surface_, buffers_[cur_], 0, 0);
    damageSurface(surface_, compositorVersion_, width_, height_);
    syncViewportLocked();
    wl_surface_commit(surface_);
    cur_ = 1 - cur_;
    wl_display_flush(display_);
}

void VoicePopup::show(InputContext *ic) {
    std::lock_guard<std::mutex> lock(mutex_);
    // show 时刻的定位决策（auto 动态回退判据见 wantTopMode）
    const auto &scr = ic->cursorRect();
    FCITX_INFO() << "VoicePopup: show 时 ic cursorRect " << scr.left()
                 << "," << scr.top() << " " << scr.width() << "x"
                 << scr.height() << " hasCursorRect_=" << hasCursorRect_
                 << " sawRealRect_=" << sawRealRect_;
    if (!ensurePopup(ic, /*atShow=*/true)) {
        FCITX_WARN() << "VoicePopup::show but popup not ready";
        return;
    }
    if (overlayFallback_ && layerSurface_) {
        applyOverlayAnchorLocked(ic); // 光标可能已移动：每次 show 重锚
    }
    if (!topMode_ || overlayFallback_) {
        // overlay 兜底（DBus 前端）也挂：preedit 经 D-Bus 送达应用，
        // 「语音输入中」指示器与其它应用观感一致
        beginPreeditProbe(ic); // 换行/重聚焦/Electron 首句实时跟随
        if (!topMode_ && lastDecisionWasKnowledgeFallback_ &&
            probeDeferralUsed_) {
            // 判定挂起：矩形到（跟随）或录音结束/保险丝（底部结算）前
            // 不 map 任何帧。不"先 popup 后切 layer"——中途换 surface 在
            // scale 发现期（首聚恰是）会放大/消失/位移
            decisionPending_ = true;
            armProbeFallbackTimer();
            FCITX_INFO() << "VoicePopup: 判定挂起——首帧延迟至矩形到达"
                            "或录音结束/8s 保险丝回退";
        }
    }
    if (patternMode_ && (!topMode_ || layerConfigured_)) {
        size_t bufSize = width_ * height_ * 4;
        uint8_t *dst = pixels_ + cur_ * bufSize;
        paintTestPattern(dst, width_, height_);
        wl_surface_attach(surface_, buffers_[cur_], 0, 0);
        damageSurface(surface_, compositorVersion_, width_, height_);
        syncViewportLocked();
        wl_surface_commit(surface_);
        cur_ = 1 - cur_;
        wl_display_flush(display_);
    }
    // 恢复输入区：创建/隐藏时设为空 region（不可见不挡交互），show 时
    // 恢复全量。surface state 随下一次 commit 生效（flutter 模式=首帧，
    // 色块模式=下方立即 commit）。注意不能放在 pushFrameBGRA 的
    // !visible_ 分支——那里是早退路径，show 已置 true，永远走不到
    if (emptyRegion_) {
        wl_surface_set_input_region(surface_, nullptr);
        FCITX_INFO() << "VoicePopup: 输入区恢复全量（show，"
                     << (topMode_ ? "layer" : "popup") << " 模式）";
    }
    // flutter 模式：不主动 commit，等 UiBridge 首帧（无 buffer 不 map）
    visible_ = true;
}

void VoicePopup::hide() {
    std::lock_guard<std::mutex> lock(mutex_);
    probeTimer_.reset();        // 会话结束，切换定时器作废
    probeDeferralUsed_ = false; // 下一会话可再用二次探测
    decisionPending_ = false;
    endPreeditProbe(); // 防御：无矩形到达的字段不留悬挂组合
    if (!surface_) {
        visible_ = false;
        return;
    }
    if (topMode_) {
        // layer 模式：不销毁 surface（下轮同 IC 直接复用，configure 已就
        // 绪）。销毁不产生 damage，niri 会残留旧画面数秒；提交全透明帧
        // 用自己的 damage 立即清掉内容
        if (buffers_[0] && layerConfigured_) {
            size_t bufSize = static_cast<size_t>(width_) * height_ * 4;
            memset(pixels_ + cur_ * bufSize, 0, bufSize);
            if (emptyRegion_) { // 隐藏即退出命中测试：不留不可见遮挡
                wl_surface_set_input_region(surface_, emptyRegion_);
            }
            wl_surface_attach(surface_, buffers_[cur_], 0, 0);
            damageSurface(surface_, compositorVersion_, width_, height_);
            syncViewportLocked();
            wl_surface_commit(surface_);
            cur_ = 1 - cur_;
        }
    } else {
        // popup 模式：classicui 同款收尾——先 attach(null)+commit 正式
        // unmap（产生 damage 清画面），再销毁。销毁是关键：smithay 的
        // input popup 追踪槽是单槽 last-create-wins，长期持有隐藏 popup
        // 会占着槽，classicui 的候选窗与我们的重定位互抢；释放后下一轮
        // show 重建即拿到最新光标矩形
        if (emptyRegion_) {
            wl_surface_set_input_region(surface_, emptyRegion_);
        }
        wl_surface_attach(surface_, nullptr, 0, 0);
        wl_surface_commit(surface_);
        destroyPopupSurface();
        FCITX_INFO() << "VoicePopup: popup 已 unmap+销毁（释放定位槽）";
    }
    visible_ = false;
    if (display_) {
        wl_display_flush(display_);
    }
}

// 重建 shm 池（帧尺寸变化时）；surface/popup 不动。
// 注意：preferredScale/outputScale/setLogicalSize 已持锁，须调
// resizeLocked——std::mutex 不可重入，持锁再调本函数=自死锁
void VoicePopup::resize(int w, int h) {
    std::lock_guard<std::mutex> lock(mutex_);
    resizeLocked(w, h);
}

void VoicePopup::resizeLocked(int w, int h) {
    if (!pool_ || (w == width_ && h == height_)) {
        return;
    }
    const size_t stride = static_cast<size_t>(w) * 4;
    const size_t bufSize = stride * h;
    const size_t needed = bufSize * 2;
    if (pool_ && needed <= poolCapacity_) {
        // 容量桶内：只重建 buffer（轻量，compositor 侧仅引用池映射的
        // 子区间）。整池重建（munmap/memfd/mmap/合成器重导入）曾是
        // 动画期间逐帧 resize 的掉帧主因，现在只在跨桶时发生
        for (auto &b : buffers_) {
            if (b) {
                wl_buffer_destroy(b);
                b = nullptr;
            }
        }
        width_ = w;
        height_ = h;
        for (int i = 0; i < 2; ++i) {
            buffers_[i] = wl_shm_pool_create_buffer(
                pool_, i * bufSize, w, h, stride, WL_SHM_FORMAT_ARGB8888);
        }
        cur_ = 0;
        return;
    }
    for (auto &b : buffers_) {
        if (b) {
            wl_buffer_destroy(b);
            b = nullptr;
        }
    }
    wl_shm_pool_destroy(pool_);
    munmap(pixels_, poolCapacity_);
    close(poolFd_);

    width_ = w;
    height_ = h;
    // 预留 1.5× + 512KB 余量：后续增长多数落在桶内
    poolCapacity_ = needed + needed / 2 + (512 << 10);
    poolFd_ = memfd_create("vi-popup", MFD_CLOEXEC);
    ftruncate(poolFd_, poolCapacity_);
    pixels_ = static_cast<uint8_t *>(
        mmap(nullptr, poolCapacity_, PROT_READ | PROT_WRITE, MAP_SHARED, poolFd_, 0));
    pool_ = wl_shm_create_pool(shm_, poolFd_, poolCapacity_);
    for (int i = 0; i < 2; ++i) {
        buffers_[i] = wl_shm_pool_create_buffer(
            pool_, i * bufSize, w, h, stride, WL_SHM_FORMAT_ARGB8888);
    }
    cur_ = 0;
    // layer surface 的 set_size 由 setLogicalSize 单点负责（这里只有物理
    // 池变化，逻辑尺寸未必变——scale 变化路径 logical 不动）
    FCITX_INFO() << "VoicePopup: shm pool resized to " << w << "x" << h;
}

// overlay 贴光标定位（classicui-X11 同款近似）：cursorRect 当输出坐标，
// 锚 TOP|LEFT + margin 摆到光标下方；放不下翻光标上方、水平钳入屏内。
// margin 随下一次 commit 生效（候选期帧持续流动，无需专门 commit）
void VoicePopup::applyOverlayAnchorLocked(InputContext *ic) {
    if (!layerSurface_) {
        return;
    }
    const auto cr = ic ? ic->cursorRect() : Rect();
    const int cw = logicalW_ > 0 ? logicalW_ : kDefaultWidth;
    const int ch = logicalH_ > 0 ? logicalH_ : kDefaultHeight;
    int x = cr.left();
    int y = cr.top() + cr.height() + 8;
    const double sc = scale();
    const int outW = outputPhysW_ > 0
                         ? static_cast<int>(outputPhysW_ / sc)
                         : 0;
    const int outH = outputPhysH_ > 0
                         ? static_cast<int>(outputPhysH_ / sc)
                         : 0;
    if (outH > 0 && y + ch > outH - 8) {
        y = cr.top() - ch - 8; // 光标下方放不下 → 翻上方
        if (y < 8) {
            y = 8;
        }
    }
    if (outW > 0) {
        x = std::max(8, std::min(x, outW - cw - 8));
    }
    zwlr_layer_surface_v1_set_anchor(
        layerSurface_, ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP |
                           ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT);
    zwlr_layer_surface_v1_set_margin(layerSurface_, y, 0, 0, x);
}

// 调用方（Dart resize 消息）上报逻辑尺寸；帧本身是物理尺寸
//（引擎按 metrics physical=逻辑×ratio 渲染），池随物理建，viewport 收逻辑
void VoicePopup::setLogicalSize(int w, int h) {
    std::lock_guard<std::mutex> lock(mutex_);
    const bool changed = w != logicalW_ || h != logicalH_;
    logicalW_ = w;
    logicalH_ = h;
    // layer surface 尺寸必须跟着卡片走（anchor 的合成器摆放按 surface
    // 尺寸算）：桶内池 resize 不重建 surface，这里不跟进的话卡片长高后
    // 底部会被 surface 边界切掉。set_size 在下一次 commit 生效
    if (topMode_ && layerSurface_ && changed) {
        zwlr_layer_surface_v1_set_size(layerSurface_, w, h);
        if (overlayFallback_) {
            applyOverlayAnchorLocked(icRef_.get()); // 尺寸变化影响翻上/钳内
        }
    }
    // destination 不急切下发（防拉伸闪烁，见 syncViewport）；物理池先按
    // 新逻辑重建，committed 的旧 buffer 在下一帧提交前按旧 destination
    // 显示
    double sc = scale();
    int pw = static_cast<int>(w * sc + 0.5);
    int ph = static_cast<int>(h * sc + 0.5);
    if (pw != width_ || ph != height_) {
        // 物理池与当前不符时先按目标逻辑比例预留（首帧到达会再校准）
        if (width_ <= 0) {
            resizeLocked(pw, ph);
        }
    }
}

// viewport destination 必须与「匹配尺寸的 buffer」同一 commit 下发：
// 提前改 destination 而表面仍是旧 buffer 的 1-2 帧内，合成器会把旧
// buffer 拉伸到新逻辑尺寸（resize/移动时的跳闪即此）。所有 commit 前
// 调本函数（池尺寸在 setLogicalSize/scale 变化时已同步重建）
void VoicePopup::syncViewportLocked() {
    if (viewport_ && logicalW_ > 0 && logicalH_ > 0) {
        wp_viewport_set_destination(viewport_, logicalW_, logicalH_);
    }
}

void VoicePopup::pushFrameBGRA(const uint8_t *bgra, int w, int h) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (w != width_ || h != height_) {
        // 池振荡防护：resize 消息已把逻辑/池更新到目标物理尺寸，而引擎
        // metrics 尚未生效时按**旧尺寸**出帧——此时把池缩回去会让窗口
        // 抖一下再长回（偶发 UI 截断的另一半根因）。旧尺寸迟到帧直接
        // 丢弃，等 metrics 更新后的新尺寸帧
        const double sc = scale();
        const int pw = static_cast<int>(logicalW_ * sc + 0.5);
        const int ph = static_cast<int>(logicalH_ * sc + 0.5);
        if (width_ == pw && height_ == ph && (w != pw || h != ph)) {
            return; // 池已在目标位，这是迟到帧
        }
        resizeLocked(w, h);
    }
    // 隐藏后丢弃迟到帧（hide 已提交透明帧，idle 态的帧会把它覆盖回来）
    // 判定挂起期同样丢帧：跟随/底部未定，不 map（杜绝中途换 surface）
    if (!visible_ || decisionPending_ || !surface_ || !buffers_[0] ||
        (topMode_ ? !layerSurface_ : !popup_)) {
        return;
    }
    if (topMode_ && !layerConfigured_) {
        return; // 首个 configure 未到，提交 buffer 是协议错误；丢帧等下一张
    }
    size_t bufSize = static_cast<size_t>(width_) * height_ * 4;
    // 引擎软渲输出即 wl_shm ARGB8888 小端字节序（BGRA），直接 memcpy
    memcpy(pixels_ + cur_ * bufSize, bgra, bufSize);
    wl_surface_attach(surface_, buffers_[cur_], 0, 0);
    damageSurface(surface_, compositorVersion_, width_, height_);
    syncViewportLocked();
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
        munmap(pixels_, poolCapacity_);
    }
    if (poolFd_ >= 0) {
        close(poolFd_);
    }
    pool_ = nullptr;
    pixels_ = nullptr;
    poolCapacity_ = 0;
    display_ = nullptr;
}

} // namespace fcitx
