/* ic-sim：纯 D-Bus 输入上下文模拟器（addon-test 容器核心工具）
 *
 * 无窗口、无显示——直接对 org.fcitx.Fcitx5 的 IM D-Bus 协议造 IC：
 *   org.fcitx.Fcitx.InputMethod1.CreateInputContext(a(ss)) → (oay)
 *   IC1: FocusIn/FocusOut/Reset/SetCursorRect(iiii)/ProcessKeyEvent(uuubu)→b
 *        SelectCandidate(i)；信号 CommitString(s)
 *
 * stdin 逐行命令，stdout 逐行事件（行缓冲，供 shell 驱动断言）：
 *   create [程序名]        造 IC（后续命令作用于它）
 *   use <程序名>            切换当前 IC
 *   focus-in / focus-out
 *   key <名|0xHEX> press|release [mods]   mods=修饰位串如 ctrl
 *   setim <名>             重建组加入该 IM 并切为当前（拼音组合测试用）
 *   rect <x> <y> <w> <h>
 *   select <i>
 *   commit-wait <文本> [超时ms]            等 CommitString 匹配
 *   sleep <ms>
 * 事件输出：commit <文本> / key <名> <p|r> filtered=<0|1> / ic <路径>
 */
#include <glib.h>
#include <gio/gio.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#define IM_IFACE "org.fcitx.Fcitx.InputMethod1"
#define IC_IFACE "org.fcitx.Fcitx.InputContext1"
#define FCITX_BUS "org.fcitx.Fcitx5"
#define IM_PATH "/org/freedesktop/portal/inputmethod"

/* X11 keysym（fcitx dbus 协议 keyval 即 X keysym） */
struct KeyName { const char *name; unsigned int sym; };
static const struct KeyName kKeys[] = {
    {"Control_R", 0xffe4}, {"Control_L", 0xffe3},
    {"Escape", 0xff1b}, {"Return", 0xff0d}, {"BackSpace", 0xff08},
    {"space", 0x20}, {"Left", 0xff51}, {"Right", 0xff53},
    {"Up", 0xff52}, {"Down", 0xff54}, {NULL, 0}};

typedef struct {
    char program[64];
    char path[128]; /* IC object path */
} Ic;

static GDBusConnection *conn;
static GMainLoop *loop;
static Ic ics[8];
static int n_ics, cur = -1;
static GString *commit_log; /* 全部 commit 事件（commit-wait 兜底匹配） */
static GMutex log_mu;

static unsigned int parse_key(const char *s) {
    if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X'))
        return (unsigned int)strtoul(s, NULL, 16);
    for (int i = 0; kKeys[i].name; i++)
        if (!strcasecmp(s, kKeys[i].name)) return kKeys[i].sym;
    if (strlen(s) == 1) return (unsigned char)s[0];
    return 0;
}

static void on_signal(GDBusConnection *c, const gchar *sender,
                      const gchar *path, const gchar *iface,
                      const gchar *member, GVariant *params,
                      gpointer user_data) {
    (void)c; (void)sender; (void)path; (void)iface; (void)user_data;
    if (!strcmp(member, "CommitString")) {
        const gchar *text = NULL;
        g_variant_get(params, "(&s)", &text);
        g_mutex_lock(&log_mu);
        g_string_append_printf(commit_log, "%s\n", text);
        g_mutex_unlock(&log_mu);
        printf("commit %s\n", text);
        fflush(stdout);
    }
}

static Ic *find_ic(const char *program) {
    for (int i = 0; i < n_ics; i++)
        if (!strcmp(ics[i].program, program)) return &ics[i];
    return NULL;
}

static void cmd_create(const char *program) {
    if (n_ics >= (int)(sizeof(ics) / sizeof(ics[0])) || !program[0]) {
        printf("ic create-failed\n"); fflush(stdout); return;
    }
    GVariantBuilder arr;
    g_variant_builder_init(&arr, G_VARIANT_TYPE("a(ss)"));
    g_variant_builder_add(&arr, "(ss)", "program", program);
    g_variant_builder_add(&arr, "(ss)", "display", "");
    /* new_tuple 无格式解析：glib 2.88 下 varargs 包裹数组变体
     * （g_variant_new("(a(ss))", v)）会把 builder 判无效、builder 直建
     * 元组又要求子项是完整数组——两坑均绕开（容器最小复现实证） */
    GVariant *children[1] = {g_variant_builder_end(&arr)};
    GVariant *params = g_variant_new_tuple(children, 1);
    GError *err = NULL;
    GVariant *ret = g_dbus_connection_call_sync(
        conn, FCITX_BUS, IM_PATH, IM_IFACE, "CreateInputContext",
        params,
        G_VARIANT_TYPE("(oay)"),
        G_DBUS_CALL_FLAGS_NONE, 5000, NULL, &err);
    if (!ret) {
        printf("ic create-failed %s\n", err ? err->message : "?");
        g_error_free(err); fflush(stdout); return;
    }
    const gchar *path = NULL;
    gchar *extra = NULL;
    g_variant_get(ret, "(&o^ay)", &path, &extra); /* (oay)：路径+字节串 */
    g_free(extra);
    Ic *ic = &ics[n_ics++];
    g_strlcpy(ic->program, program, sizeof(ic->program));
    g_strlcpy(ic->path, path, sizeof(ic->path));
    cur = n_ics - 1;
    char *rule = g_strdup_printf("type='signal',interface='%s',path='%s'",
                                 IC_IFACE, ic->path);
    g_dbus_connection_signal_subscribe(conn, FCITX_BUS, IC_IFACE, NULL,
                                       ic->path, NULL,
                                       G_DBUS_SIGNAL_FLAGS_NONE, on_signal,
                                       NULL, NULL);
    printf("ic %s %s\n", ic->program, ic->path);
    g_variant_unref(ret);
    g_free(rule);
    fflush(stdout);
}

static void call_ic(const char *method, GVariant *args, const char *fmt_out,
                    char *out, size_t out_sz) {
    if (cur < 0) { printf("err no-ic\n"); fflush(stdout); return; }
    GError *err = NULL;
    const GVariantType *ty = fmt_out && fmt_out[0]
                                 ? g_variant_type_new(fmt_out) : NULL;
    GVariant *ret = g_dbus_connection_call_sync(
        conn, FCITX_BUS, ics[cur].path, IC_IFACE, method, args, ty,
        G_DBUS_CALL_FLAGS_NONE, 5000, NULL, &err);
    if (!ret) {
        printf("err %s: %s\n", method, err ? err->message : "?");
        g_error_free(err); fflush(stdout); return;
    }
    if (out_sz && out) {
        if (ty) {
            /* 单返回值解包 */
            if (!strcmp(fmt_out, "(b)")) {
                gboolean v = FALSE; g_variant_get(ret, "(b)", &v);
                snprintf(out, out_sz, "%d", v);
            }
        }
    }
    g_variant_unref(ret);
    fflush(stdout);
}

/* setim：把 <名> 加进当前组并切成当前 IM。
 * 组名单必须从总线取——"Default" 名会被 zh_CN locale 翻译，硬编码必踩。
 * SetCurrentIM 要求目标 IM 已在组列表里（否则静默 no-op），所以先重建组 */
static void cmd_setim(const char *name) {
    GError *err = NULL;
    GVariant *ret = g_dbus_connection_call_sync(
        conn, FCITX_BUS, "/controller", "org.fcitx.Fcitx.Controller1",
        "CurrentInputMethodGroup", NULL, G_VARIANT_TYPE("(s)"),
        G_DBUS_CALL_FLAGS_NONE, 5000, NULL, &err);
    if (!ret) {
        printf("setim %s err group: %s\n", name, err ? err->message : "?");
        g_error_free(err); fflush(stdout); return;
    }
    const gchar *group = NULL;
    g_variant_get(ret, "(&s)", &group);
    GVariantBuilder arr;
    g_variant_builder_init(&arr, G_VARIANT_TYPE("a(ss)"));
    g_variant_builder_add(&arr, "(ss)", "keyboard-us", "");
    g_variant_builder_add(&arr, "(ss)", name, "");
    /* 与 create 同款 new_tuple 法绕 glib 2.88 varargs 数组坑 */
    GVariant *children[3] = {
        g_variant_new_string(group), g_variant_new_string("us"),
        g_variant_builder_end(&arr)};
    GVariant *params = g_variant_new_tuple(children, 3);
    err = NULL;
    if (!g_dbus_connection_call_sync(
            conn, FCITX_BUS, "/controller", "org.fcitx.Fcitx.Controller1",
            "SetInputMethodGroupInfo", params, NULL,
            G_DBUS_CALL_FLAGS_NONE, 5000, NULL, &err)) {
        printf("setim %s err groupinfo: %s\n", name, err ? err->message : "?");
        g_error_free(err); fflush(stdout); return;
    }
    err = NULL;
    if (!g_dbus_connection_call_sync(
            conn, FCITX_BUS, "/controller", "org.fcitx.Fcitx.Controller1",
            "SetCurrentIM", g_variant_new("(s)", name), NULL,
            G_DBUS_CALL_FLAGS_NONE, 5000, NULL, &err)) {
        printf("setim %s err current: %s\n", name, err ? err->message : "?");
        g_error_free(err); fflush(stdout); return;
    }
    printf("setim %s ok\n", name);
    fflush(stdout);
}

int main(int argc, char **argv) {
    (void)argc; (void)argv;
    setvbuf(stdout, NULL, _IOLBF, 0);
    GError *err = NULL;
    conn = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &err);
    if (!conn) {
        fprintf(stderr, "ic-sim: 会话总线连接失败: %s\n", err->message);
        return 2;
    }
    commit_log = g_string_new(NULL);
    loop = g_main_loop_new(NULL, FALSE);

    char line[512];
    char pending_commit[256] = "";
    gint64 commit_deadline = 0;
    while (fgets(line, sizeof(line), stdin)) {
        g_strchomp(line);
        if (!line[0] || line[0] == '#') continue;
        gchar **t = g_strsplit(line, " ", 0);
        const gchar *cmd = t[0];
        if (!strcmp(cmd, "create")) {
            cmd_create(t[1] && t[1][0] ? t[1] : "ic-sim");
        } else if (!strcmp(cmd, "use")) {
            Ic *ic = t[1] ? find_ic(t[1]) : NULL;
            if (ic) cur = (int)(ic - ics);
            printf("use %s\n", ic ? ic->program : "not-found");
        } else if (!strcmp(cmd, "focus-in")) {
            call_ic("FocusIn", NULL, "", NULL, 0);
            printf("focus-in ok\n");
        } else if (!strcmp(cmd, "focus-out")) {
            call_ic("FocusOut", NULL, "", NULL, 0);
            printf("focus-out ok\n");
        } else if (!strcmp(cmd, "key") && t[1] && t[2]) {
            unsigned int sym = parse_key(t[1]);
            int release = !strcmp(t[2], "release") || !strcmp(t[2], "r");
            unsigned int mods = 0;
            if (t[3]) {
                if (strstr(t[3], "ctrl")) mods |= 1u << 2;
                if (strstr(t[3], "shift")) mods |= 1u << 0;
                if (strstr(t[3], "alt")) mods |= 1u << 3;
            }
            char out[16] = "?";
            call_ic("ProcessKeyEvent",
                    g_variant_new("(uuubu)", sym, sym, mods, release,
                                  (guint32)(g_get_monotonic_time() / 1000)),
                    "(b)", out, sizeof(out));
            printf("key %s %s filtered=%s\n", t[1], release ? "r" : "p", out);
        } else if (!strcmp(cmd, "setim") && t[1]) {
            cmd_setim(t[1]);
        } else if (!strcmp(cmd, "rect") && t[1] && t[2] && t[3] && t[4]) {
            call_ic("SetCursorRect",
                    g_variant_new("(iiii)", atoi(t[1]), atoi(t[2]),
                                  atoi(t[3]), atoi(t[4])),
                    "", NULL, 0);
            printf("rect ok\n");
        } else if (!strcmp(cmd, "select") && t[1]) {
            call_ic("SelectCandidate", g_variant_new("(i)", atoi(t[1])),
                    "", NULL, 0);
            printf("select ok\n");
        } else if (!strcmp(cmd, "commit-wait") && t[1]) {
            g_strlcpy(pending_commit, t[1], sizeof(pending_commit));
            commit_deadline = g_get_monotonic_time() +
                              (gint64)(t[2] ? atoi(t[2]) : 8000) * 1000;
            printf("commit-wait %s\n", pending_commit);
        } else if (!strcmp(cmd, "sleep") && t[1]) {
            g_usleep(1000 * (guint64)atoi(t[1]));
            printf("sleep %s ok\n", t[1]);
        } else {
            printf("err unknown: %s\n", line);
        }
        g_strfreev(t);
        fflush(stdout);

        /* commit-wait 轮询：处理主循环事件并检查匹配 */
        while (pending_commit[0] &&
               g_get_monotonic_time() < commit_deadline) {
            g_main_context_iteration(NULL, FALSE);
            g_mutex_lock(&log_mu);
            gboolean hit = strstr(commit_log->str, pending_commit) != NULL;
            g_mutex_unlock(&log_mu);
            if (hit) {
                printf("commit-ok %s\n", pending_commit);
                pending_commit[0] = 0;
                break;
            }
            g_usleep(50000);
        }
        if (pending_commit[0]) {
            printf("commit-timeout %s\n", pending_commit);
            pending_commit[0] = 0;
        }
    }
    /* 排空剩余信号 */
    for (int i = 0; i < 10; i++) g_main_context_iteration(NULL, FALSE);
    return 0;
}
