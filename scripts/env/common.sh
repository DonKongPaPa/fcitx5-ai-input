#!/usr/bin/env bash
# 容器内公共编排函数：被各环境 start-*.sh source 使用
# 前提：整个测试脚本运行在 dbus-run-session 之下
set -euo pipefail

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || true

LOG_DIR="${LOG_DIR:-/tmp/logs}"
OUT_DIR="${OUT_DIR:-/tmp/out}"
mkdir -p "$LOG_DIR" "$OUT_DIR"

# 环境：fcitx5 输入法模块走 GTK/Qt 的 fcitx IM 模块（应用直连 fcitx5，D-Bus 通信）
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
export XMODIFIERS=@im=fcitx
export SDL_IM_MODULE=fcitx
export GLFW_IM_MODULE=ibus   # flutter linux (glfw) 兼容
export LIBGL_ALWAYS_SOFTWARE=1

# 输入法环境只保留 voiceinput，避免其他引擎干扰
export INPUT_METHOD=fcitx

wait_wayland_socket() {
    local sock="$1" tries="${2:-60}"
    for _ in $(seq 1 "$tries"); do
        [ -S "$XDG_RUNTIME_DIR/$sock" ] && return 0
        sleep 0.5
    done
    echo "等待 Wayland socket $sock 超时" >&2
    return 1
}

wait_dbus_name() {
    local name="$1" tries="${2:-60}"
    for _ in $(seq 1 "$tries"); do
        if busctl --user --no-pager status "$name" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.5
    done
    echo "等待 D-Bus 名称 $name 超时" >&2
    return 1
}

# 音频栈：pipewire + pulse 兼容层 + wireplumber
start_audio() {
    pipewire >"$LOG_DIR/pipewire.log" 2>&1 &
    pipewire-pulse >"$LOG_DIR/pipewire-pulse.log" 2>&1 &
    wireplumber >"$LOG_DIR/wireplumber.log" 2>&1 &
    # 等待 pulse 兼容层可用
    for _ in $(seq 1 40); do
        pactl info >/dev/null 2>&1 && break
        sleep 0.5
    done
    pactl info >/dev/null 2>&1 || { echo "pipewire/pulse 启动失败"; return 1; }
}

# 虚拟麦克风：null sink 的 monitor 即"麦克风采集到的声音"
# 用法：play_to_mic file.wav —— 将测试音频作为麦克风输入播放
setup_virtual_mic() {
    VIRTUAL_MIC_SINK="vi_mic"
    # pipewire 刚启动时 load-module 可能报 Not supported，重试
    local tries=0 id=""
    while [ $tries -lt 10 ]; do
        id="$(pactl load-module module-null-sink sink_name="$VIRTUAL_MIC_SINK" \
            sink_properties=device.description=voiceinput-test-mic 2>>"$LOG_DIR/pactl-load.log" || true)"
        [ -n "$id" ] && break
        tries=$((tries + 1))
        sleep 1
    done
    [ -n "$id" ] || { echo "虚拟麦克风创建失败"; return 1; }
    pactl set-default-source "${VIRTUAL_MIC_SINK}.monitor"
    echo "$VIRTUAL_MIC_SINK"
}

play_to_mic() {
    local wav="$1"
    pw-play --target "$VIRTUAL_MIC_SINK" "$wav" >"$LOG_DIR/pw-play.log" 2>&1
}

# fcitx5 守护进程（加载我们的 addon：dist 预先安装在容器 /opt/dist）
start_fcitx5() {
    fcitx5 -d --replace >"$LOG_DIR/fcitx5.log" 2>&1
    wait_dbus_name org.fcitx.Fcitx5 60
    # 只启用 voiceinput 输入法
    # (配置由 run-test.sh 在启动前写入 ~/.config/fcitx5/profile)
}

# 通用收尾：杀掉本会话拉起的所有后台进程
cleanup_all() {
    jobs -p | xargs -r kill 2>/dev/null || true
}
