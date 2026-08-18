/* voiceinput 测试应用（GTK4）
 *
 * 单窗口文本框：焦点/文本变化时以 JSON 行输出当前缓冲区（stdout + TEST_RESULT_FILE），
 * 供管线断言 fcitx5 提交的文本是否落点正确。
 * 内置 500ms 重绘定时器：niri/wlroots 按需渲染，需要持续 damage 才能保证录屏连续。
 */
#include <gtk/gtk.h>
#include <stdio.h>
#include <time.h>

static gint64 mono_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (gint64)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* 极简 JSON 字符串转义（测试文本仅含中英文与标点） */
static void json_escape(GString *out, const char *s) {
    for (const char *p = s; *p; p++) {
        switch (*p) {
        case '"': g_string_append(out, "\\\""); break;
        case '\\': g_string_append(out, "\\\\"); break;
        case '\n': g_string_append(out, "\\n"); break;
        default: g_string_append_c(out, *p);
        }
    }
}

static void emit_json(GtkEntry *entry, const char *event) {
    const char *text = gtk_editable_get_text(GTK_EDITABLE(entry));
    GString *j = g_string_new("");
    g_string_printf(j, "{\"app\":\"gtk4\",\"event\":\"");
    json_escape(j, event);
    g_string_append(j, "\",\"text\":\"");
    json_escape(j, text);
    g_string_append_printf(j, "\",\"mono_ms\":%" G_GINT64_FORMAT "}\n", mono_ms());

    fputs(j->str, stdout);
    fflush(stdout);
    const char *path = g_getenv("TEST_RESULT_FILE");
    if (path) {
        FILE *f = fopen(path, "a");
        if (f) { fputs(j->str, f); fclose(f); }
    }
    g_string_free(j, TRUE);
}

static void on_changed(GtkEditable *editable, gpointer user_data) {
    emit_json(GTK_ENTRY(editable), "changed");
}

static void on_focus_in(GtkEventControllerFocus *ctrl, gpointer user_data) {
    emit_json(GTK_ENTRY(user_data), "focus-in");
}

/* 持续重绘：保证录屏帧连续（wlroots/niri 按需渲染）。
 * 注意 queue_draw 内容不变时 GTK4 不产生真实 damage，niri 对静止应用
 * 的输出重绘周期可长达 ~3.4s（IM popup 等 overlay 更新被拖慢）——
 * 用标题变化制造每秒真实 damage，模拟真实打字应用 */
static gboolean on_tick(gpointer user_data) {
    static int sec = 0;
    char buf[64];
    snprintf(buf, sizeof(buf), "voiceinput-testapp-gtk %d", sec++);
    gtk_window_set_title(GTK_WINDOW(user_data), buf);
    gtk_widget_queue_draw(GTK_WIDGET(user_data));
    return G_SOURCE_CONTINUE;
}

static gboolean on_timeout(gpointer user_data) {
    g_application_quit(G_APPLICATION(user_data));
    return G_SOURCE_REMOVE;
}

static void on_activate(GtkApplication *app, gpointer user_data) {
    GtkWidget *win = gtk_application_window_new(app);
    gtk_window_set_title(GTK_WINDOW(win), "voiceinput-testapp-gtk");
    gtk_window_set_default_size(GTK_WINDOW(win), 640, 220);

    GtkWidget *entry = gtk_entry_new();
    gtk_entry_set_placeholder_text(GTK_ENTRY(entry), "语音输入落点……");
    /* 文字行贴窗口顶：GtkEntry 默认在(被平铺拉高的)窗口里垂直居中，光标
     * 矩形会落到窗口中部，IM popup 跟着挂到窗口中下部——顶部对齐后 popup
     * 紧随标题栏，贴近真实单行输入框的体验 */
    gtk_widget_set_valign(entry, GTK_ALIGN_START);
    gtk_window_set_child(GTK_WINDOW(win), entry);

    g_signal_connect(entry, "changed", G_CALLBACK(on_changed), NULL);
    GtkEventController *focus = gtk_event_controller_focus_new();
    g_signal_connect(focus, "enter", G_CALLBACK(on_focus_in), entry);
    gtk_widget_add_controller(entry, focus);

    gtk_window_present(GTK_WINDOW(win));
    gtk_widget_grab_focus(entry);

    g_timeout_add(500, on_tick, win);

    const char *timeout_s = g_getenv("TEST_TIMEOUT");
    int timeout = timeout_s ? atoi(timeout_s) : 120;
    if (timeout > 0) g_timeout_add_seconds(timeout, on_timeout, app);
}

int main(int argc, char **argv) {
    GtkApplication *app = gtk_application_new("org.fcitx5.voiceinput.testapp",
                                              G_APPLICATION_DEFAULT_FLAGS);
    g_signal_connect(app, "activate", G_CALLBACK(on_activate), NULL);
    int rc = g_application_run(G_APPLICATION(app), argc, argv);
    g_object_unref(app);
    return rc;
}
