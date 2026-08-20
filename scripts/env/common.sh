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
    # pipewire 主进程/pipewire-pulse 的 pulse 模块加载互抢 socket（结果随
    # 时序变化，多种翻法实测）。回归朴素三行启动 + 一次自愈重试（竞态
    # 结果轮次间会变，重试即高概率成功）
    _pw_start() {
        pipewire >"$LOG_DIR/pipewire.log" 2>&1 &
        pipewire-pulse >"$LOG_DIR/pipewire-pulse.log" 2>&1 &
        wireplumber >"$LOG_DIR/wireplumber.log" 2>&1 &
        for _ in $(seq 1 40); do
            pactl info >/dev/null 2>&1 && break
            sleep 0.5
        done
        pactl info >/dev/null 2>&1
    }
    if ! _pw_start; then
        echo "audio 首次启动未就绪，自愈重试一次"
        pkill -x pipewire 2>/dev/null || true
        pkill -x pipewire-pulse 2>/dev/null || true
        pkill -x wireplumber 2>/dev/null || true
        rm -rf "${XDG_RUNTIME_DIR:-/run/user/1000}/pulse" 2>/dev/null || true
        sleep 1
        _pw_start || { echo "pipewire/pulse 启动失败"; return 1; }
    fi
}

# 虚拟麦克风：null sink 的 monitor 即"麦克风采集到的声音"
# 用法：play_to_mic file.wav —— 将测试音频作为麦克风输入播放
setup_virtual_mic() {
    VIRTUAL_MIC_SINK="vi_mic"
    # pipewire 刚启动时 load-module 可能报 Not supported，重试。坑：pactl
    # 的错误文本打在 stdout（"Failure: Not supported" 非空会被当成模块
    # ID 判成功，set-default-source 再炸 + set -e 杀全局——会话首跑翻车
    # 的真凶）——必须校验纯数字，并以 source 真正存在为准
    local tries=0 id=""
    while [ $tries -lt 15 ]; do
        id="$(pactl load-module module-null-sink sink_name="$VIRTUAL_MIC_SINK" \
            sink_properties=device.description=voiceinput-test-mic 2>>"$LOG_DIR/pactl-load.log" || true)"
        case "$id" in
            ''|*[!0-9]*) id="" ;;
        esac
        [ -n "$id" ] && break
        tries=$((tries + 1))
        sleep 1
    done
    local ok=""
    for _ in $(seq 1 20); do
        if pactl list short sources 2>/dev/null | grep -q "${VIRTUAL_MIC_SINK}.monitor"; then
            ok=1
            break
        fi
        sleep 0.5
    done
    [ -n "$ok" ] || { echo "虚拟麦克风创建失败"; return 1; }
    pactl set-default-source "${VIRTUAL_MIC_SINK}.monitor" >/dev/null 2>&1 || true
    echo "$VIRTUAL_MIC_SINK"
}

play_to_mic() {
    local wav="$1"
    # case-driver 是 start-niri 的子进程，未 export 的 VIRTUAL_MIC_SINK
    # 传不下去——默认 vi_mic 与 setup_virtual_mic 一致
    pw-play --target "${VIRTUAL_MIC_SINK:-vi_mic}" "$wav" >"$LOG_DIR/pw-play.log" 2>&1
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
