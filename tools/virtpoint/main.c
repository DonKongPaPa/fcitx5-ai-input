/* virtpoint：wlr-virtual-pointer-v1 注入工具（测试用）
 * 用法：
 *   virtpoint move X Y [XEXT YEXT]   绝对移动（默认 extent 1280x720）
 *   virtpoint click [left|right]     按下+释放
 * 事件经 niri 的 VirtualPointerInputBackend 进入真实指针流。
 */
#define _GNU_SOURCE 1
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "wayland-client.h"
#include "wlr-virtual-pointer-unstable-v1-client-protocol.h"

static struct wl_seat *seat;
static struct zwlr_virtual_pointer_manager_v1 *mgr;
static int has_mgr, has_seat;

static uint32_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint32_t)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}

static void registry_global(void *data, struct wl_registry *r, uint32_t name,
                            const char *iface, uint32_t version) {
    (void)data;
    if (strcmp(iface, "wl_seat") == 0 && !seat) {
        seat = wl_registry_bind(r, name, &wl_seat_interface, 1);
        has_seat = 1;
    } else if (strcmp(iface, "zwlr_virtual_pointer_manager_v1") == 0 && !mgr) {
        mgr = wl_registry_bind(r, name,
                               &zwlr_virtual_pointer_manager_v1_interface, 1);
        has_mgr = 1;
    }
}
static void registry_global_remove(void *data, struct wl_registry *r,
                                   uint32_t name) {
    (void)data;
    (void)r;
    (void)name;
}
static const struct wl_registry_listener reg_listener = {
    registry_global, registry_global_remove};

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr,
                "用法: virtpoint move X Y [XEXT YEXT] | virtpoint click [left|right]\n");
        return 1;
    }
    struct wl_display *d = wl_display_connect(NULL);
    if (!d) {
        fprintf(stderr, "wl_display_connect 失败（WAYLAND_DISPLAY=%s）\n",
                getenv("WAYLAND_DISPLAY") ?: "(null)");
        return 1;
    }
    struct wl_registry *reg = wl_display_get_registry(d);
    wl_registry_add_listener(reg, &reg_listener, NULL);
    wl_display_roundtrip(d);
    if (!has_mgr || !has_seat) {
        fprintf(stderr, "合成器缺少 zwlr_virtual_pointer_manager_v1 / wl_seat\n");
        return 2;
    }
    struct zwlr_virtual_pointer_v1 *vp =
        zwlr_virtual_pointer_manager_v1_create_virtual_pointer(mgr, seat);

    if (strcmp(argv[1], "move") == 0 && argc >= 4) {
        int x = atoi(argv[2]), y = atoi(argv[3]);
        int xe = (argc >= 6) ? atoi(argv[4]) : 1280;
        int ye = (argc >= 6) ? atoi(argv[5]) : 720;
        zwlr_virtual_pointer_v1_motion_absolute(vp, now_ms(), x, y, xe, ye);
        zwlr_virtual_pointer_v1_frame(vp);
    } else if (strcmp(argv[1], "click") == 0) {
        uint32_t btn = 0x110; // BTN_LEFT
        if (argc >= 3 && strcmp(argv[2], "right") == 0) {
            btn = 0x111; // BTN_RIGHT
        }
        uint32_t t = now_ms();
        zwlr_virtual_pointer_v1_button(vp, t, btn, 1);
        zwlr_virtual_pointer_v1_frame(vp);
        zwlr_virtual_pointer_v1_button(vp, t + 30, btn, 0);
        zwlr_virtual_pointer_v1_frame(vp);
    } else {
        fprintf(stderr, "参数错误\n");
        return 1;
    }
    wl_display_flush(d);
    wl_display_roundtrip(d);
    return 0;
}
