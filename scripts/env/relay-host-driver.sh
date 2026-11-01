#!/usr/bin/env bash
# relay-host driver（frame-relay.md §5 T1/T2/T3-lite）：离屏渲染宿主
#（aiinput-card-host）全链路验证——纯 QML 档（FlutterCard=False）下引擎
# spawn 宿主进程，帧经 VoicePopup 的 input-popup surface 由合成器定位。
# 断言全部截图/日志实证：T1 帧上屏（候选面板贴 caret）、T2 caret 三位置
# 跟随、T3-lite 语音 recording 态一帧。宿主无窗口（offscreen），双显在
# 结构上不可能——截图仍目检兜底。
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

FCITX_LOG="$LOG_DIR/fcitx5-relay.log"
DIST_BIN="${DIST_BIN:-/opt/dist/bin}"
call() { timeout 30 gdbus call --session --dest org.fcitx.Fcitx5 \
    --object-path /org/fcitx/AiInput \
    --method org.fcitx.AiInput.Test."$1" "${@:2}" 2>&1; }
shot() { WAYLAND_DISPLAY="$CAGE_SOCK" timeout 10 grim "$1" 2>/dev/null || true; }

echo "== 0) 写纯 QML relay 配置并重启 fcitx5"
mkdir -p "$HOME/.config/fcitx5/conf"
printf 'FlutterCard=False\nQmlCard=True\n' > "$HOME/.config/fcitx5/conf/aiinput.config"
# socket 文件存在性轮询（忙轮询：bind 后文件哪怕存在 1μs 也会被抓到）
( T0=$(date +%s)
  while [ $(( $(date +%s) - T0 )) -lt 45 ]; do
      if [ -e /run/user/1000/aiinput-card.sock ]; then
          echo "$(date +%T.%3N) EXISTS"
      fi
  done ) >"$OUT_DIR/sock-poll.log" 2>&1 &
POLL_PID=$!
pkill -x fcitx5 2>/dev/null || true
sleep 1
# STRACE_FCHEB（诊断轮可选）：罩住 fcitx5 重启，抓 socket 路径的 unlink 凶手
if [ -n "${STRACE_FCHEB:-}" ] && command -v strace >/dev/null 2>&1; then
    strace -f -qq -e trace=bind,unlink,unlinkat -o "$OUT_DIR/strace-flow.log" \
        fcitx5 --verbose '*' -d --replace >"$FCITX_LOG" 2>&1 || true
else
    fcitx5 --verbose '*' -d --replace >"$FCITX_LOG" 2>&1 || true
fi
for _ in $(seq 1 30); do
    timeout 5 gdbus call --session --dest org.fcitx.Fcitx5 \
        --object-path /controller \
        --method org.fcitx.Fcitx.Controller1.CurrentUI >/dev/null 2>&1 && break
    sleep 0.5
done
timeout 10 gdbus call --session --dest org.fcitx.Fcitx5 \
    --object-path /controller \
    --method org.fcitx.Fcitx.Controller1.CurrentUI || true

echo "== 1) 宿主 spawn + 双通道连接（控制 + 帧通道）"
for _ in $(seq 1 40); do
    grep -aq "帧通道已连接" "$FCITX_LOG" && break
    sleep 0.5
done
grep -aq "aiinput-card-host" "$FCITX_LOG" \
    && echo "✓ 宿主已 spawn" || echo "✗ 宿主未 spawn"
grep -aq "QML 卡片已连接" "$FCITX_LOG" \
    && echo "✓ 控制通道已连接" || echo "✗ 控制通道未连接"
grep -aq "帧通道已连接" "$FCITX_LOG" \
    && echo "✓ 帧通道已连接" || echo "✗ 帧通道未连接"

# 连接失败取证（会话侧视角——与 host 子进程视角对照，判挂载/可见性分歧）
if ! grep -aq "帧通道已连接" "$FCITX_LOG"; then
    {
        echo "== $(date +%T) driver 视角 /run/user/1000："
        ls -la /run/user/1000/ 2>&1
        echo "== socket 文件 stat："
        stat /run/user/1000/aiinput-card.sock 2>&1 || true
        echo "== mount namespace 三方对照："
        echo "driver : $(readlink /proc/self/ns/mnt 2>&1)"
        F5PID="$(pgrep -x fcitx5 | tail -1)"
        echo "fcitx5($F5PID): $(readlink /proc/$F5PID/ns/mnt 2>&1)"
        HPID="$(pgrep -f aiinput-card-host | tail -1)"
        echo "host($HPID): $(readlink /proc/$HPID/ns/mnt 2>&1)"
        echo "== fcitx5 mountinfo /run 行："
        grep " /run" "/proc/$F5PID/mountinfo" 2>&1 || true
        echo "== driver mountinfo /run 行："
        grep " /run" /proc/self/mountinfo 2>&1 || true
        echo "== 内核 socket 表（aiinput 行；@前缀=abstract）=="
        grep aiinput /proc/net/unix 2>&1 || echo "NONE in /proc/net/unix"
        echo "== 按 inode 找 dentry（root 侧全盘）=="
        for ino in $(grep aiinput /proc/net/unix 2>/dev/null | awk '{print $10}' | sort -u); do
            echo "inode=$ino:"
            find /run/user/1000 -maxdepth 1 -inum "$ino" 2>/dev/null
            find /run/user/1000/. -maxdepth 1 -inum "$ino" 2>/dev/null
        done
        echo "== 目录里全部名字（含隐藏/怪名）=="
        ls -lab /run/user/1000/ 2>&1 | grep -i aiinput || echo "无 aiinput 字样"
        echo "== fcitx5 的 socket fd 数与 root 视角 =="
        ls -la "/proc/$F5PID/fd" 2>/dev/null | grep -c socket || true
        ls "/proc/$F5PID/root/run/user/1000/" 2>&1 | grep aiinput \
            || echo "fcitx5 root 视角也无"
        echo "== fcitx5 cmdline 与 root 指针 =="
        tr '\0' ' ' < "/proc/$F5PID/cmdline" 2>&1; echo
        ls -la "/proc/$F5PID/root" 2>&1 | head -2
        echo "== fcitx5 XDG_RUNTIME_DIR："
        tr '\0' '\n' < "/proc/$F5PID/environ" 2>&1 | grep XDG_RUNTIME || true
        echo "== driver uid："
        id
        echo "== 进程树："
        ps -ef | grep -E "fcitx5|aiinput-card-host" | grep -v grep
    } > "$OUT_DIR/session-view.txt" 2>&1
fi

echo "== 2) 双窗口（第二列=非原点，跟随断言不靠原点巧合）"
"$DIST_BIN/testapp-gtk" >"$LOG_DIR/testapp-r1.log" 2>&1 &
sleep 1.5
"$DIST_BIN/testapp-gtk" >"$LOG_DIR/testapp-r2.log" 2>&1 &
sleep 1.5
timeout 10 "$DIST_BIN/virtpoint" move 1400 300 1280 720 2>/dev/null || true
timeout 10 "$DIST_BIN/virtpoint" click left 2>/dev/null || true
sleep 1

echo "== 3) ic-sim：语音一态（T3-lite）→ Esc → pinyin nihao → caret 三位（T2）"
( printf 'create t1 t1\nuse 1\nfocus-in\nrect 540 300 8 50\nsleep 400\n\
key Control_R press ctrl\nsleep 1400\n\
key Control_R release ctrl\nsleep 2600\n\
key Escape press\nkey Escape release\nsleep 600\n\
setim pinyin\nsleep 300\n\
key n press\nkey n release\nsleep 350\n\
key i press\nkey i release\nsleep 350\n\
key h press\nkey h release\nsleep 350\n\
key a press\nkey a release\nsleep 350\n\
key o press\nkey o release\nsleep 1500\n\
rect 900 500 8 50\nsleep 1200\n\
rect 200 850 8 50\nsleep 1200\n\
rect 1300 300 8 50\nsleep 1200\n\
sleep 3000\n' | timeout 26 "$DIST_BIN/ic-sim" 2>>"$LOG_DIR/ic-sim.err" ) &
IC_PID=$!

# 时序对齐：rect+400ms press → 450ms 阈值 → recording（~t+2.5s 截语音帧）
sleep 3
shot "$OUT_DIR/relay-voice.png"
# release→tail→asr final→Esc→pinyin 5 键（~t+9.5s 起候选）；~t+11/12.2/13.4
# 三次 rect 重锚——t+11.2/12.4/13.6 各截一张
sleep 5
shot "$OUT_DIR/relay-panel-posA.png"
sleep 1.2
shot "$OUT_DIR/relay-panel-posB.png"
sleep 1.2
shot "$OUT_DIR/relay-panel-posC.png"
sleep 1.2
shot "$OUT_DIR/relay-panel-posD.png"
wait "$IC_PID" 2>/dev/null || true

echo "== 4) 帧证据与异常扫描"
echo "-- [relay] 帧到达（C++ 侧）："
grep -a "\[relay\] frame" "$FCITX_LOG" | tail -8
echo "-- CARD-HOST 帧渲染（宿主侧 stderr 直通）："
grep -a "CARD-HOST: frame" "$FCITX_LOG" | tail -8
echo "-- QML 异常扫描（应为空）："
grep -aE "QML error|Cannot assign|TypeError|ReferenceError" "$FCITX_LOG" | head -5 || true
echo "-- CurrentUI："
timeout 10 gdbus call --session --dest org.fcitx.Fcitx5 \
    --object-path /controller \
    --method org.fcitx.Fcitx.Controller1.CurrentUI || true
echo "-- 存活："
call State || true
# RELAY_HOLD：活体诊断窗口（诊断场景保持合成器/fcitx5 不退场）
sleep "${RELAY_HOLD:-0}"
kill "$POLL_PID" 2>/dev/null || true
