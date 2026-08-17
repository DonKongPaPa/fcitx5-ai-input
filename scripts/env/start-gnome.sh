#!/usr/bin/env bash
# GNOME 环境容器内编排：gnome-shell 无头运行，内置 Screencast D-Bus 录屏
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

DURATION="${DURATION:-10}"
MODE="${MODE:-sleep}"

# 1. gnome-shell 无头（新版本为 CI 提供的 --headless；失败则回退 mutter）
ls "$XDG_RUNTIME_DIR" | grep -E '^wayland-[0-9]+$' | sort >"$LOG_DIR/sockets.before" || true
gnome-shell --wayland --headless >"$LOG_DIR/gnome-shell.log" 2>&1 &
GNOME_PID=$!

GNOME_SOCK=""
for _ in $(seq 1 90); do
    ls "$XDG_RUNTIME_DIR" | grep -E '^wayland-[0-9]+$' | sort >"$LOG_DIR/sockets.now" || true
    GNOME_SOCK="$(comm -13 "$LOG_DIR/sockets.before" "$LOG_DIR/sockets.now" | head -1 || true)"
    [ -n "$GNOME_SOCK" ] && break
    # 进程死掉提前退出
    kill -0 "$GNOME_PID" 2>/dev/null || break
    sleep 0.5
done
if [ -z "$GNOME_SOCK" ]; then
    echo "gnome-shell --headless 失败，回退 mutter："
    tail -20 "$LOG_DIR/gnome-shell.log" >&2 || true
    mutter --wayland --headless >"$LOG_DIR/mutter.log" 2>&1 &
    GNOME_PID=$!
    for _ in $(seq 1 90); do
        ls "$XDG_RUNTIME_DIR" | grep -E '^wayland-[0-9]+$' | sort >"$LOG_DIR/sockets.now" || true
        GNOME_SOCK="$(comm -13 "$LOG_DIR/sockets.before" "$LOG_DIR/sockets.now" | head -1 || true)"
        [ -n "$GNOME_SOCK" ] && break
        kill -0 "$GNOME_PID" 2>/dev/null || break
        sleep 0.5
    done
fi
[ -n "$GNOME_SOCK" ] || { echo "gnome/mutter socket 未出现"; exit 1; }
export WAYLAND_DISPLAY="$GNOME_SOCK"
echo "gnome 就绪：socket=$GNOME_SOCK（pid=$GNOME_PID）"

# 2. 公共栈
start_audio
setup_virtual_mic >/dev/null
start_fcitx5

# 3. 录屏：gnome-shell 内置 Screencast（org.gnome.Shell.Screencast）
#    仅 gnome-shell 模式可用；mutter 回退模式下跳过录屏（M2 验证后处理）
HAS_SHELL_CAST=no
if busctl --user status org.gnome.Shell.Screencast >/dev/null 2>&1 \
   || gdbus call --session --dest org.gnome.Shell.Screencast \
        --object-path /org/gnome/Shell/Screencast >/dev/null 2>&1; then
    HAS_SHELL_CAST=yes
    mkdir -p "$OUT_DIR/gnome-screencast"
    gdbus call --session \
        --dest org.gnome.Shell.Screencast \
        --object-path /org/gnome/Shell/Screencast \
        --method org.gnome.Shell.Screencast.Screencast \
        "$OUT_DIR/gnome-screencast/cast" >"$LOG_DIR/screencast.log" 2>&1 || \
        HAS_SHELL_CAST=no
fi
echo "gnome Screencast: $HAS_SHELL_CAST"

# 4. 测试动作（M2：仅验证）
echo "环境验证运行 ${DURATION}s ……"
if [ "$MODE" = "shell" ]; then
    exec bash
fi
sleep "$DURATION"

# 5. 收尾
if [ "$HAS_SHELL_CAST" = "yes" ]; then
    gdbus call --session \
        --dest org.gnome.Shell.Screencast \
        --object-path /org/gnome/Shell/Screencast \
        --method org.gnome.Shell.Screencast.StopScreencast >>"$LOG_DIR/screencast.log" 2>&1 || true
fi
kill "$GNOME_PID" 2>/dev/null || true
cleanup_all

ls -la "$OUT_DIR"
echo "gnome 环境验证完成"
