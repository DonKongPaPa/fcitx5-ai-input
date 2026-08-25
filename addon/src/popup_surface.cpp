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
#include <fcitx/event.h>
#include <fcitx/inputcontext.h>
#include <fcitx/inputpanel.h>
#include <fcitx-utils/event.h>
#include <fcitx/text.h>
#include <xcb/shm.h>
#include <xcb_public.h>
#include <wayland_public.h>

#include <fcntl.h>
#include <sys/ipc.h>
#include <sys/shm.h>

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
#include "xdg-output-unstable-v1-client-protocol.h"
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

void VoicePopup::recomputeScaleLocked() {
    if (surfaceOutput_) {
        auto it = outputs_.find(surfaceOutput_);
        if (it != outputs_.end() && it->second.scale() > 0) {
            cachedScale_ = it->second.scale();
            return;
        }
    }
    for (const auto &kv : outputs_) { // 无 enter 信息：任一可推导输出
        if (kv.second.scale() > 0) {
            cachedScale_ = kv.second.scale();
            return;
        }
    }
    cachedScale_ = gotFscale_    ? scaleNum_ / 120.0
                   : lastFscaleNum_ > 0 ? lastFscaleNum_ / 120.0
                                        : outputScale_;
}

void VoicePopup::xdgLogicalSize(void *data, zxdg_output_v1 *xo,
                                  int32_t w, int32_t h) {
    // 输出真实逻辑尺寸（zxdg）——与 mode 物理尺寸相除得精确分数 scale。
    // xdgOwner_ 定位是哪个输出（listener data 与 user_data 同槽，见
    // surfaceEnter 注释——这里 data 仍是 this，未受影响？否——同槽！
    // zxdg proxy 无 compat hack，data 安全为 this）
    auto *s = static_cast<VoicePopup *>(data);
    std::lock_guard<std::mutex> lock(s->mutex_);
    if (auto it = s->xdgOwner_.find(xo); it != s->xdgOwner_.end()) {
        auto &g = s->outputs_[it->second];
        g.logicalW = w;
        g.logicalH = h;
        s->recomputeScaleLocked();
    }
}

void VoicePopup::surfaceEnter(void *data, wl_surface *, wl_output *o) {
    // libwayland 陷阱：listener data 与 wl_proxy_set_user_data 同槽。
    // 我们 surface 的 user_data 被经典 UI 兼容 calloc 块占用——listener
    // data 也是它。块头部存 this 反向指针（classicui 只读 +0x48）
    auto **owner = static_cast<VoicePopup **>(data);
    auto *s = *owner;
    std::lock_guard<std::mutex> lock(s->mutex_);
    s->surfaceOutput_ = o;
    s->recomputeScaleLocked();
}

void VoicePopup::surfaceLeave(void *data, wl_surface *, wl_output *o) {
    auto **owner = static_cast<VoicePopup **>(data);
    auto *s = *owner;
    std::lock_guard<std::mutex> lock(s->mutex_);
    if (s->surfaceOutput_ == o) {
        s->surfaceOutput_ = nullptr;
        s->recomputeScaleLocked();
    }
}

static const wl_surface_listener kSurfaceListener = {
    /* .enter = */ &VoicePopup::surfaceEnter,
    /* .leave = */ &VoicePopup::surfaceLeave,
    /* .preferred_buffer_scale = */ // v5 槽空即 abort（libwayland 行为）
    [](void *, wl_surface *, int32_t) {},
    /* .preferred_buffer_transform = */
    [](void *, wl_surface *, uint32_t) {},
};

void VoicePopup::xdgLogicalPos(void *data, zxdg_output_v1 *xo, int32_t x,
                               int32_t y) {
    // 输出在全局布局中的逻辑原点——XWayland 输出区段判定用
    //（X 屏把输出摆在逻辑原点、范围取物理尺寸）
    auto *s = static_cast<VoicePopup *>(data);
    std::lock_guard<std::mutex> lock(s->mutex_);
    if (auto it = s->xdgOwner_.find(xo); it != s->xdgOwner_.end()) {
        s->outputs_[it->second].logicalX = x;
        s->outputs_[it->second].logicalY = y;
    }
}

static const zxdg_output_v1_listener kXdgOutputListener = {
    /* .logical = */ &VoicePopup::xdgLogicalPos,
    /* .logical_size = */ &VoicePopup::xdgLogicalSize,
    /* .done = */ [](void *, zxdg_output_v1 *) {},
    /* .name = */ [](void *, zxdg_output_v1 *, const char *) {},
    /* .description = */ [](void *, zxdg_output_v1 *, const char *) {},
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
    s->recomputeScaleLocked();
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
void VoicePopup::outputMode(void *data, wl_output *o, uint32_t,
                            int32_t w, int32_t h, int32_t) {
    auto *s = static_cast<VoicePopup *>(data);
    std::lock_guard<std::mutex> lock(s->mutex_);
    s->outputs_[o].physW = w;
    s->outputs_[o].physH = h;
    s->recomputeScaleLocked();
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
            surfaceOutput_ = nullptr;
            outputs_.clear();
            xdgOwner_.clear();
            cachedScale_ = 0;
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
    // DBus 前端 IC 的光标矩形变化（应用 SetCursorRect → 事件）：
    // follow 档下卡片实时贴光标（重锚在已映射的 layer surface 上，
    // 随下一次帧 commit 生效）
    rectWatcher_ = instance_->watchEvent(
        EventType::InputContextCursorRectChanged,
        EventWatcherPhase::PreInputMethod, [this](Event &event) {
            auto &ie = static_cast<InputContextEvent &>(event);
            auto *ic = ie.inputContext();
            std::lock_guard<std::mutex> lock(mutex_);
            if (dbusFollow_ && overlayFallback_ && ic == icRef_.get()) {
                if (!x11Mode_) {
                    // 首次 FocusIn 时 program 未到（空串）会先落 layer：
                    // 矩形变化时 program 已就位则升级成 X OR 窗
                    tryUpgradeToX11Locked(ic);
                }
                // X 应用走 OR 窗重摆；wayland 原生走 layer 重锚
                if (x11Mode_) {
                    if (ic->cursorRect().height() > 0) {
                        moveX11WindowLocked(ic->cursorRect());
                    }
                } else if (layerSurface_) {
                    anchorOverlayLocked(ic);
                }
            }
        });
}

// overlay 兜底层的锚定。DbusPosition=follow 且 IC 带非零光标矩形时贴
// 光标：矩形是 Qt/GTK 的窗口局部逻辑坐标，对「铺满输出的面板」（DMS
// 单窗 spotlight：锚 top+left+right+bottom 铺满，实测矩形即输出绝对
// 坐标）与原点起铺的平铺/最大化窗口成立。翻转/钳制按「包含矩形的输
// 出」几何算——矩形本就产自该输出。无矩形/非 follow 档维持底部（或
// policy top）居中：普通浮动 DBus 窗口的窗口原点 Wayland 不暴露，
// 贴光标结构性做不到，那类应用就该用 bottom
void VoicePopup::anchorOverlayLocked(InputContext *ic) {
    if (!layerSurface_) {
        return;
    }
    Rect rect;
    if (ic) {
        rect = ic->cursorRect();
    }
    // 高度判有效性（GTK4 的 caret 矩形宽度为 0——线条光标没有宽度）；
    // 全零矩形（chromium 焦点期恒 0,0 0x0）由高度 0 拒掉
    if (!dbusFollow_ || rect.height() <= 0) {
        zwlr_layer_surface_v1_set_anchor(
            layerSurface_, anchorBottom_
                               ? ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM
                               : ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP);
        zwlr_layer_surface_v1_set_margin(
            layerSurface_, anchorBottom_ ? 0 : 16, 0,
            anchorBottom_ ? 16 : 0, 0);
        return;
    }
    const OutputGeom *geom = nullptr;
    if (!geom) {
        // 无 X 信息：含矩形的最小输出（重叠布局下取小者更可信）
        double best = 0;
        for (const auto &kv : outputs_) {
            const auto &g = kv.second;
            if (g.logicalW <= 0 || g.logicalH <= 0 ||
                g.logicalW < rect.left() || g.logicalH < rect.top()) {
                continue;
            }
            const double area = double(g.logicalW) * g.logicalH;
            if (!geom || area < best) {
                geom = &g;
                best = area;
            }
        }
    }
    constexpr int kGap = 8;
    int x = rect.left();
    int top = rect.top() + rect.height() + kGap;
    if (geom && logicalW_ > 0) {
        x = std::clamp(x, kGap,
                       std::max(kGap, geom->logicalW - logicalW_ - kGap));
        if (top + logicalH_ > geom->logicalH - kGap) {
            // 下方放不下：翻到光标上方（顶仍越界则贴输出顶兜底）
            top = std::max(kGap, rect.top() - logicalH_ - kGap);
        }
    }
    zwlr_layer_surface_v1_set_anchor(
        layerSurface_, ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP |
                           ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT);
    zwlr_layer_surface_v1_set_margin(layerSurface_, top, 0, 0, x);
    if (top != lastAnchorTop_ || x != lastAnchorLeft_) {
        // 光标每动一次就来一条会刷屏：只记落点变化
        lastAnchorTop_ = top;
        lastAnchorLeft_ = x;
        FCITX_INFO() << "VoicePopup: overlay 贴光标锚定（矩形 "
                     << rect.left() << "," << rect.top() << " → 卡片左上 "
                     << x << "," << top << "）";
    }
}

void VoicePopup::setDbusFollow(bool follow) {
    std::lock_guard<std::mutex> lock(mutex_);
    dbusFollow_ = follow;
    if (overlayFallback_ && layerSurface_) {
        anchorOverlayLocked(icRef_.get());
    }
}

// ---------------------------------------------------------------------------
// XWayland 矩形换算：X 屏的输出区段=逻辑原点+物理范围（xrandr 实测），
// X 坐标是物理像素。classicui 对此类 IC 走 X11 窗口（X 坐标直接摆放）
// 天然对位；我们是 wayland 层表面（逻辑 margin），必须转。
// ---------------------------------------------------------------------------
void VoicePopup::ensureX11Atoms() {
    // 独立连接自产 atom（intern_atom 同步各一次，每进程只做一遍）
    auto intern = [this](const char *name) -> xcb_atom_t {
        auto *r = xcb_intern_atom_reply(
            xconn_, xcb_intern_atom(xconn_, 0, strlen(name), name), nullptr);
        xcb_atom_t a = r ? r->atom : XCB_ATOM_NONE;
        free(r);
        return a;
    };
    xAtomActiveWindow_ = intern("_NET_ACTIVE_WINDOW");
    xAtomWmClass_ = intern("WM_CLASS");
    xAtomClientList_ = intern("_NET_CLIENT_LIST");
}

// layer → X OR 窗升级：program 异步到达后的补判（首 FocusIn 时空串）
void VoicePopup::tryUpgradeToX11Locked(InputContext *ic) {
    if (x11Mode_ || !dbusFollow_ || !overlayFallback_ || !ic ||
        ic != icRef_.get()) {
        return;
    }
    const Rect rect = ic->cursorRect();
    // 溢出铁证 || 聚焦窗是 X 应用（活动窗存在）
    if (!rectIsXPhysical(rect) && !focusedX11WindowLocked()) {
        return;
    }
    // 判成 X 应用：拆 layer 表面，改走 X OR 窗（首帧到达时建窗）
    destroyPopupSurface();
    x11Mode_ = true;
    if (ic->cursorRect().height() > 0) {
        xLastRect_ = ic->cursorRect();
    }
    if (modeSwitchHandler_) {
        modeSwitchHandler_(); // 引擎重推一帧 → X 窗建窗
    }
    FCITX_INFO() << "VoicePopup: X OR 卡片模式（矩形变化时升级，rect="
                 << rect.left() << "," << rect.top() << " program="
                 << ic->program() << "）";
}

// 矩形是否为 X 物理坐标：超出所有输出的逻辑范围（含一点容差）即铁证
// ——wayland 原生应用报逻辑值，逻辑值不可能大于输出逻辑尺寸
bool VoicePopup::rectIsXPhysical(const Rect &rect) {
    if (rect.height() <= 0) {
        return false;
    }
    int32_t maxW = 0, maxH = 0;
    for (const auto &kv : outputs_) {
        maxW = std::max(maxW, kv.second.logicalW);
        maxH = std::max(maxH, kv.second.logicalH);
    }
    if (maxW <= 0 || maxH <= 0) {
        return false; // 输出几何未知：无法判
    }
    // 容差 2：wayland 逻辑值最多到逻辑尺寸-1，任何超出都是物理坐标
    return rect.left() > maxW + 2 || rect.top() > maxH + 2;
}

bool VoicePopup::focusedX11WindowLocked() {
    // 活动窗存在 ⟺ 聚焦应用是 X 应用：FocusIn 的 IC 就是聚焦应用，
    // 而 satellite 在 wayland 应用聚焦时清空 _NET_ACTIVE_WINDOW（实测
    // active=0x0）——program/WM_CLASS 都不需要（program 实测会恒空）。
    // 溢出铁证之外的第二判据；两者任一命中即 X 模式
    if (xBroken_ || !xconn_ || xroot_ == XCB_WINDOW_NONE) {
        if (xBroken_) {
            return false;
        }
    }
    if (!xTried_) {
        xTried_ = true;
        auto *xcb = instance_->addonManager().addon("xcb", true);
        if (!xcb) {
            FCITX_INFO() << "VoicePopup: [x11diag] xcb addon 不可用";
            xBroken_ = true;
            return false;
        }
        auto name = xcb->call<IXCBModule::mainDisplay>();
        FCITX_INFO() << "VoicePopup: [x11diag] xcb 主显示=\"" << name << "\"";
        if (name.empty() || !xcb->call<IXCBModule::isXWayland>(name)) {
            xBroken_ = true;
            return false;
        }
        int screen = 0;
        xconn_ = xcb_connect(name.c_str(), &screen);
        if (xcb_connection_has_error(xconn_)) {
            FCITX_INFO() << "VoicePopup: [x11diag] xcb_connect 失败 err="
                         << xcb_connection_has_error(xconn_);
            xcb_disconnect(xconn_);
            xconn_ = nullptr;
            xBroken_ = true;
            return false;
        }
        auto it = xcb_setup_roots_iterator(xcb_get_setup(xconn_));
        for (int i = 0; i < screen && it.rem > 1; ++i) {
            xcb_screen_next(&it);
        }
        xroot_ = it.data->root;
        xRootW_ = it.data->width_in_pixels;
        xRootH_ = it.data->height_in_pixels;
        ensureX11Atoms();
        ensureX11EventSource();
        xcb_flush(xconn_);
    }
    if (!xconn_ || xroot_ == XCB_WINDOW_NONE) {
        return false;
    }
    auto *r = xcb_get_property_reply(
        xconn_,
        xcb_get_property(xconn_, 0, xroot_, xAtomActiveWindow_,
                         XCB_ATOM_WINDOW, 0, 1),
        nullptr);
    bool active = false;
    if (r && r->type != XCB_ATOM_NONE &&
        xcb_get_property_value_length(r) >= 4) {
        auto w = *static_cast<const xcb_window_t *>(
            xcb_get_property_value(r));
        // 有效活动窗：非空、非根、非我们自己的卡片窗
        active = w != XCB_WINDOW_NONE && w != xroot_ && w != xwin_;
    }
    free(r);
    if (xcb_connection_has_error(xconn_)) {
        FCITX_INFO() << "VoicePopup: [x11diag] 查询中连接死掉";
        xBroken_ = true;
        return false;
    }
    if (active != xActiveLast_) {
        xActiveLast_ = active;
        FCITX_INFO() << "VoicePopup: [x11diag] 活动 X 窗 "
                     << (active ? "存在（聚焦应用=X）" : "无（聚焦应用=wayland）");
    }
    return active;
}

// ---------------------------------------------------------------------------
// X OR 卡片窗：classicui 同款传输层（satellite→xdg_popup→聚焦 X 顶层窗，
// 合成器叠加真实窗口原点——右列/多输出由 satellite+niri 处理）
// ---------------------------------------------------------------------------
void VoicePopup::ensureX11EventSource() {
    if (xEventSrc_ || !xconn_) {
        return;
    }
    int fd = xcb_get_file_descriptor(xconn_);
    if (fd < 0) {
        return;
    }
    xEventSrc_ = instance_->eventLoop().addIOEvent(
        fd, IOEventFlag::In, [this](EventSourceIO *, int, IOEventFlags) {
            handleX11Events();
            return true;
        });
}

void VoicePopup::handleX11Events() {
    std::lock_guard<std::mutex> lock(mutex_);
    while (auto *e = xcb_poll_for_event(xconn_)) {
        if (e->response_type == 0) { // X 错误（此前静默吞——BadGC 等）
            if (xErrLog_ < 8) {
                ++xErrLog_;
                auto *xerr = reinterpret_cast<xcb_generic_error_t *>(e);
                FCITX_WARN() << "VoicePopup: [x11diag] X 错误 code="
                             << int(xerr->error_code) << " seq="
                             << xerr->sequence;
            }
            free(e);
            continue;
        }
        switch (e->response_type & 0x7f) {
        case XCB_EXPOSE: {
            // 重贴当前帧（SHM 段内容仍在）
            if (xwin_ != XCB_WINDOW_NONE && xshm_ != XCB_NONE &&
                xwinW_ > 0) {
                xcb_shm_put_image(xconn_, xwin_, xgc_, xwinW_, xwinH_, 0, 0,
                                  xwinW_, xwinH_, 0, 0, xDepth_,
                                  XCB_IMAGE_FORMAT_Z_PIXMAP, 0, xshm_, 0);
                xcb_flush(xconn_);
            }
            break;
        }
        case XCB_ENTER_NOTIFY: {
            auto *ev = reinterpret_cast<xcb_enter_notify_event_t *>(e);
            if (ev->event == xwin_ && ev->detail != XCB_NOTIFY_DETAIL_INFERIOR) {
                pointerOnPopup_ = true;
                ptrX_ = ev->event_x;
                ptrY_ = ev->event_y;
                if (pointerSink_) {
                    pointerSink_(PointerEvent::Enter, ptrX_, ptrY_);
                }
            }
            break;
        }
        case XCB_LEAVE_NOTIFY: {
            auto *ev = reinterpret_cast<xcb_leave_notify_event_t *>(e);
            if (ev->event == xwin_ && ev->detail != XCB_NOTIFY_DETAIL_INFERIOR) {
                pointerOnPopup_ = false;
                if (pointerSink_) {
                    pointerSink_(PointerEvent::Leave, ptrX_, ptrY_);
                }
            }
            break;
        }
        case XCB_MOTION_NOTIFY: {
            auto *ev = reinterpret_cast<xcb_motion_notify_event_t *>(e);
            if (ev->event == xwin_) {
                ptrX_ = ev->event_x;
                ptrY_ = ev->event_y;
                if (pointerOnPopup_ && pointerSink_) {
                    // X 坐标即物理像素——与 Flutter metrics 同空间直送
                    pointerSink_(PointerEvent::Motion, ptrX_, ptrY_);
                }
            }
            break;
        }
        case XCB_BUTTON_PRESS:
        case XCB_BUTTON_RELEASE: {
            auto *ev = reinterpret_cast<xcb_button_press_event_t *>(e);
            if (ev->event == xwin_ && ev->detail == 1 && pointerOnPopup_ &&
                pointerSink_) {
                ptrX_ = ev->event_x;
                ptrY_ = ev->event_y;
                pointerSink_(
                    ev->response_type == XCB_BUTTON_PRESS
                        ? PointerEvent::Press
                        : PointerEvent::Release,
                    ptrX_, ptrY_);
            }
            break;
        }
        default:
            break;
        }
        free(e);
    }
}

void VoicePopup::moveX11WindowLocked(const Rect &rect) {
    xLastRect_ = rect;
    if (xwin_ == XCB_WINDOW_NONE || !xconn_) {
        return;
    }
    const auto xy = x11CardPosLocked(rect, xwinW_, xwinH_);
    const uint32_t vals[2] = {static_cast<uint32_t>(xy.first),
                              static_cast<uint32_t>(xy.second)};
    xcb_configure_window(xconn_, xwin_,
                         XCB_CONFIG_WINDOW_X | XCB_CONFIG_WINDOW_Y, vals);
    xcb_flush(xconn_);
}

// X 卡片落点：caret 下方放不下翻上方、水平钳入 caret 所在输出的 X 区段
//（satellite 不替我们滑——ghostty 末行输入卡片出屏的实测）
std::pair<int, int> VoicePopup::x11CardPosLocked(const Rect &rect, int cardW,
                                                 int cardH) {
    const int gap = static_cast<int>(8 * scale() + 0.5);
    int x = rect.left();
    int y = rect.top() + rect.height() + gap;
    // 含 caret 的输出 X 区段：位置=逻辑原点、范围=物理尺寸
    const OutputGeom *g = nullptr;
    for (const auto &kv : outputs_) {
        if (kv.second.containsXPoint(rect.left(), rect.top())) {
            g = &kv.second;
            break;
        }
    }
    if (g && cardW > 0 && cardH > 0) {
        const int rx0 = g->logicalX, ry0 = g->logicalY;
        const int rx1 = g->logicalX + g->physW, ry1 = g->logicalY + g->physH;
        x = std::clamp(x, rx0 + kGapX11,
                       std::max(rx0 + kGapX11, rx1 - cardW - kGapX11));
        if (y + cardH > ry1 - kGapX11) {
            y = std::max(ry0 + kGapX11, rect.top() - cardH - gap);
        }
    }
    // X 屏硬界：OR 卡片越出 X 屏（root 尺寸）时 satellite 无法父子化，
    // 会把它映成独立顶层窗——niri 给新窗键盘焦点，会话 IC 失焦、触发键
    // 永远到不了（ghostty 末行卡片 y=2288 出 1512 屏卡死实测）。矩形本身
    // 出屏（GTK 滚动文档坐标虚报、悬浮窗超出 X 屏）也一并兜住：先翻到
    // 光标上方，再钳回屏内
    if (xRootW_ > 0 && xRootH_ > 0 && cardW > 0 && cardH > 0) {
        if (y + cardH > xRootH_ - kGapX11) {
            y = std::max(kGapX11, rect.top() - cardH - gap);
        }
        x = std::clamp(x, kGapX11, std::max(kGapX11, xRootW_ - cardW - kGapX11));
        y = std::clamp(y, kGapX11, std::max(kGapX11, xRootH_ - cardH - kGapX11));
    }
    return {x, y};
}

void VoicePopup::pushFrameX11Locked(const uint8_t *bgra, int w, int h) {
    if (!visible_ || !xconn_ || xBroken_) {
        return;
    }
    const size_t bytes = static_cast<size_t>(w) * h * 4;
    if (w != xwinW_ || h != xwinH_ || !xshmAddr_) {
        // SHM 段重建
        if (xshm_ != XCB_NONE) {
            xcb_shm_detach(xconn_, xshm_);
            xcb_flush(xconn_);
            xshm_ = XCB_NONE;
        }
        if (xshmAddr_) {
            shmdt(xshmAddr_);
            shmctl(xshmid_, IPC_RMID, nullptr);
            xshmAddr_ = nullptr;
        }
        xshmid_ = shmget(IPC_PRIVATE, bytes, IPC_CREAT | 0600);
        if (xshmid_ < 0) {
            xBroken_ = true;
            FCITX_WARN() << "VoicePopup: shmget 失败，X 卡片路径弃用";
            return;
        }
        xshmAddr_ =
            static_cast<uint8_t *>(shmat(xshmid_, nullptr, 0));
        if (xshmAddr_ == reinterpret_cast<uint8_t *>(-1)) {
            xshmAddr_ = nullptr;
            shmctl(xshmid_, IPC_RMID, nullptr);
            xBroken_ = true;
            return;
        }
        xshmSize_ = bytes;
        xshm_ = xcb_generate_id(xconn_);
        xcb_shm_attach(xconn_, xshm_, xshmid_, false);
        xwinW_ = w;
        xwinH_ = h;
        xcb_screen_t *scr =
            xcb_setup_roots_iterator(xcb_get_setup(xconn_)).data;
        if (xwin_ == XCB_WINDOW_NONE) {
            const int gap = static_cast<int>(8 * scale() + 0.5);
            // 32 位 ARGB visual：卡片四周的阴影余量/圆角/半透明阴影带
            // alpha，24 位深度下全渲染成黑（WPS 黑边实测）。visual/
            // colormap 每连接找一次
            if (xVisual_ == 0) {
                for (auto d = xcb_screen_allowed_depths_iterator(scr);
                     d.rem && xVisual_ == 0; xcb_depth_next(&d)) {
                    if (d.data->depth != 32) {
                        continue;
                    }
                    for (auto v = xcb_depth_visuals_iterator(d.data); v.rem;
                         xcb_visualtype_next(&v)) {
                        if (v.data->_class == XCB_VISUAL_CLASS_TRUE_COLOR) {
                            xVisual_ = v.data->visual_id;
                            break;
                        }
                    }
                }
                if (xVisual_ == 0) {
                    xVisual_ = scr->root_visual; // 退化：无 32 位则黑边
                    xDepth_ = 24;
                } else {
                    xDepth_ = 32;
                    xColormap_ = xcb_generate_id(xconn_);
                    xcb_create_colormap(xconn_, XCB_COLORMAP_ALLOC_NONE,
                                        xColormap_, xroot_, xVisual_);
                }
            }
            xwin_ = xcb_generate_id(xconn_);
            // 值列表必须按 CW 位序（独立程序实证：border<save<
            // override<event<colormap；顺序写反＝BadValue 窗口建不成）
            uint32_t mask = XCB_CW_BORDER_PIXEL | XCB_CW_SAVE_UNDER |
                            XCB_CW_OVERRIDE_REDIRECT | XCB_CW_EVENT_MASK |
                            (xDepth_ == 32 ? XCB_CW_COLORMAP : 0);
            uint32_t vals[5] = {
                0, // border_pixel
                1, // save_under
                1, // override_redirect
                XCB_EVENT_MASK_EXPOSURE | XCB_EVENT_MASK_STRUCTURE_NOTIFY |
                    XCB_EVENT_MASK_ENTER_WINDOW | XCB_EVENT_MASK_LEAVE_WINDOW |
                    XCB_EVENT_MASK_POINTER_MOTION |
                    XCB_EVENT_MASK_BUTTON_PRESS |
                    XCB_EVENT_MASK_BUTTON_RELEASE |
                    XCB_EVENT_MASK_BUTTON_MOTION,
                xColormap_};
            const auto xy = x11CardPosLocked(xLastRect_, w, h);
            xcb_create_window(xconn_, xDepth_, xwin_, xroot_, xy.first,
                              xy.second, w, h, 0,
                              XCB_WINDOW_CLASS_INPUT_OUTPUT, xVisual_, mask,
                              vals);
            xgc_ = xcb_generate_id(xconn_);
            xcb_create_gc(xconn_, xgc_, xwin_, 0, nullptr);
            xcb_map_window(xconn_, xwin_);
            FCITX_INFO() << "VoicePopup: X OR 卡片窗 0x" << std::hex
                         << xwin_ << std::dec << " " << w << "x" << h
                         << " @ " << xy.first << "," << xy.second
                         << "（rect=" << xLastRect_.left() << ","
                         << xLastRect_.top() << " root=" << xRootW_ << "x"
                         << xRootH_ << "）";
        } else {
            const uint32_t vals[2] = {static_cast<uint32_t>(w),
                                      static_cast<uint32_t>(h)};
            xcb_configure_window(
                xconn_, xwin_,
                XCB_CONFIG_WINDOW_WIDTH | XCB_CONFIG_WINDOW_HEIGHT, vals);
        }
    }
    if (xwin_ == XCB_WINDOW_NONE) {
        return;
    }
    memcpy(xshmAddr_, bgra, bytes);
    xcb_shm_put_image(xconn_, xwin_, xgc_, w, h, 0, 0, w, h, 0, 0, xDepth_,
                      XCB_IMAGE_FORMAT_Z_PIXMAP, 0, xshm_, 0);
    xcb_flush(xconn_);
}

void VoicePopup::destroyX11WindowLocked() {
    if (xwin_ != XCB_WINDOW_NONE && xconn_) {
        xcb_unmap_window(xconn_, xwin_);
        xcb_destroy_window(xconn_, xwin_);
        xcb_flush(xconn_);
    }
    // GC 的 drawable 随窗失效：留着必 BadGC（曾致 put_image 全败、
    // 窗口映射着但全透明不可见）
    if (xgc_ != XCB_NONE && xconn_) {
        xcb_free_gc(xconn_, xgc_);
        xcb_flush(xconn_);
    }
    xgc_ = XCB_NONE;
    xwin_ = XCB_WINDOW_NONE;
    xwinW_ = xwinH_ = 0;
    if (xshm_ != XCB_NONE && xconn_) {
        xcb_shm_detach(xconn_, xshm_);
        xshm_ = XCB_NONE;
    }
    if (xshmAddr_) {
        shmdt(xshmAddr_);
        shmctl(xshmid_, IPC_RMID, nullptr);
        xshmAddr_ = nullptr;
    }
    pointerOnPopup_ = false;
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
    } else if (strcmp(iface, "wl_output") == 0) {
        // 多输出全绑：scale 按表面所在输出推导（双屏 1.25+1.5 时用首
        // 输出的推导值会把副屏卡片渲染错比例——等比缩小的双屏变体）
        auto *o = static_cast<wl_output *>(
            wl_registry_bind(reg, name, &wl_output_interface, 2));
        wl_output_add_listener(o, &kOutputListener, self);
        if (!self->output_) {
            self->output_ = o; // 首输出：整数 scale 兜底
        }
        self->outputs_[o] = OutputGeom{};
        FCITX_INFO() << "VoicePopup: wl_output bound v2 name=" << name;
        if (self->xdgOutputMgr_) {
            auto *xo =
                zxdg_output_manager_v1_get_xdg_output(self->xdgOutputMgr_, o);
            self->xdgOwner_[xo] = o;
            zxdg_output_v1_add_listener(xo, &kXdgOutputListener, self);
        }
    } else if (strcmp(iface, "zxdg_output_manager_v1") == 0 &&
               !self->xdgOutputMgr_) {
        self->xdgOutputMgr_ = static_cast<zxdg_output_manager_v1 *>(
            wl_registry_bind(reg, name, &zxdg_output_manager_v1_interface,
                             2));
        for (auto &kv : self->outputs_) {
            auto *xo =
                zxdg_output_manager_v1_get_xdg_output(self->xdgOutputMgr_,
                                                      kv.first);
            self->xdgOwner_[xo] = kv.first;
            zxdg_output_v1_add_listener(xo, &kXdgOutputListener, self);
        }
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
    // X 应用的 overlay 兜底走 X OR 窗口（classicui 同款传输层）：
    // satellite 把 OR 窗转 xdg_popup 挂聚焦 X 顶层窗，真实窗口原点由
    // 合成器叠加——wayland 层拿不到 X 应用的窗口原点（右列错位根因）
    // 判据：①矩形超出全部输出的逻辑范围 → 只可能是 X 物理坐标（wayland
    // 原生应用的矩形 ≤ 其窗口 ≤ 输出逻辑尺寸）→ 铁证 X 应用，无需
    // program；②program 非空时 WM_CLASS 匹配（辅证）。program 时序坑：
    // DBus 前端首次 FocusIn（乃至整个会话）program 可能恒为空串
    //（实测 WPS 在新 fcitx5 进程里从不到达）——矩形溢出是唯一可靠信号
    if (overlay && dbusFollow_ &&
        (rectIsXPhysical(ic->cursorRect()) || focusedX11WindowLocked())) {
        lastProgram_ = toLower(ic->program());
        if (x11Mode_ && icRef_.get() == ic) {
            return true; // 同 IC 复用
        }
        destroyPopupSurface();
        destroyX11WindowLocked();
        topMode_ = false;
        overlayFallback_ = true;
        x11Mode_ = true;
        icRef_ = ic->watch();
        if (ic->cursorRect().height() > 0) {
            xLastRect_ = ic->cursorRect();
        }
        FCITX_INFO() << "VoicePopup: X OR 卡片模式（矩形溢出判定，rect="
                     << ic->cursorRect().left() << "," << ic->cursorRect().top()
                     << "）";
        return true;
    }
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
    destroyX11WindowLocked(); // 模式可能从 X 切回 wayland（IC 换应用）
    topMode_ = top;
    overlayFallback_ = overlay;
    x11Mode_ = false;

    surface_ = wl_compositor_create_surface(compositor_);
    // 注意顺序陷阱：libwayland 的 listener data 与 set_user_data 同槽，
    // 下方的 compat calloc 会覆盖——calloc 块头部写入 this 反指针供
    // surfaceEnter/Leave 取回（经典 UI thunk 只读 +0x48，头部安全）
    wl_surface_add_listener(surface_, &kSurfaceListener, this);
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
    *static_cast<VoicePopup **>(surfaceCompat_) = this;
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
        // overlay 兜底锚定：follow 档贴光标（坐标系论证见
        // anchorOverlayLocked）；默认/无矩形底部居中。policy top/bottom
        //（非 overlay）走原锚点
        if (overlayFallback_) {
            anchorOverlayLocked(ic);
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
                     << (overlayFallback_ ? "overlay 兜底" : anchorBottom_ ? "底部" : "顶部")
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
    if (x11Mode_) {
        // 首帧建窗的定位源；探针照常走 D-Bus（下方 show 分支）
        if (ic->cursorRect().height() > 0) {
            xLastRect_ = ic->cursorRect();
        }
        return;
    }
    if (overlayFallback_ && dbusFollow_) {
        // FocusIn 时光标矩形新鲜：复用的表面也要按新矩形重锚
        anchorOverlayLocked(ic);
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
    if (patternMode_ && !x11Mode_ && (!topMode_ || layerConfigured_)) {
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
    if (emptyRegion_ && surface_) {
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
    if (x11Mode_) {
        destroyX11WindowLocked();
        visible_ = false;
        return;
    }
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

// 调用方（Dart resize 消息）上报逻辑尺寸；帧本身是物理尺寸
//（引擎按 metrics physical=逻辑×ratio 渲染），池随物理建，viewport 收逻辑
void VoicePopup::setLogicalSize(int w, int h) {
    std::lock_guard<std::mutex> lock(mutex_);
    const bool changed = w != logicalW_ || h != logicalH_;
    logicalW_ = w;
    logicalH_ = h;
    // follow 档的翻转/钳制按卡片尺寸算：idle(≈54)→候选(≈190) 的高度跳变
    // 必须重锚，否则按旧高度翻转会把卡片底部裁出输出边缘
    if (overlayFallback_ && dbusFollow_ && layerSurface_) {
        anchorOverlayLocked(icRef_.get());
    }
    // layer surface 尺寸必须跟着卡片走（anchor 的合成器摆放按 surface
    // 尺寸算）：桶内池 resize 不重建 surface，这里不跟进的话卡片长高后
    // 底部会被 surface 边界切掉。set_size 在下一次 commit 生效
    if (topMode_ && layerSurface_ && changed) {
        zwlr_layer_surface_v1_set_size(layerSurface_, w, h);
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
    if (x11Mode_) {
        if (!visible_ || decisionPending_ || xBroken_) {
            return;
        }
        // 迟到帧防护同 wayland 路径：目标物理尺寸不符直接丢
        const double sc = scale();
        const int pw = static_cast<int>(logicalW_ * sc + 0.5);
        const int ph = static_cast<int>(logicalH_ * sc + 0.5);
        if (pw > 0 && (w != pw || h != ph)) {
            return;
        }
        pushFrameX11Locked(bgra, w, h);
        return;
    }
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
    if (xconn_) {
        xcb_disconnect(xconn_);
        xconn_ = nullptr;
    }
    if (!display_) {
        return;
    }
    destroyPopupSurface();
    destroyX11WindowLocked();
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
