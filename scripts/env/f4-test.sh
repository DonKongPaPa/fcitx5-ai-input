#!/usr/bin/env bash
# F4 验证：MD3 Flutter UI 经帧桥显示在光标附近（录屏帧差断言）
#
# 拓扑：
#   cage1(headless) → niri → testapp(GTK text-input-v3) ← fcitx5 + addon
#                                                ↑ popup surface（光标附近）
#   cage2(headless) → flutter voice_ui 窗口（addon 拉起，不进入录屏画面）
#        addon ←TCP帧← flutter（RepaintBoundary.toImage 快照）
#
# 断言（popup bbox 取自 F3 实测 x[186,545] y[40,239]）：
#   1) 触发后 bbox 内出现 UI（与触发前帧差）
#   2) 录音期间 bbox 内容持续变化（计时/流式 partial → 帧间差）
#   3) 候选态 bbox 内容再变化（UI 状态切换）
set -u
export XDG_RUNTIME_DIR=/run/user/1000
export LIBGL_ALWAYS_SOFTWARE=1
unset GTK_IM_MODULE QT_IM_MODULE

call() { gdbus call --session --dest org.fcitx.Fcitx5 --object-path /org/fcitx/VoiceInput \
    --method org.fcitx.VoiceInput.Test."$1" "${@:2}" 2>&1; }

# —— cage1：niri 宿主（录屏对象）——
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER_ALLOW_SOFTWARE=1 \
    cage -d -s niri >/tmp/cage.log 2>&1 &
niri_sock=""
for i in $(seq 1 30); do
    niri_sock=$(ls "$XDG_RUNTIME_DIR" | grep -oP '^niri\.\K[^.]+' | head -1)
    [ -n "$niri_sock" ] && break; sleep 0.5
done
export WAYLAND_DISPLAY=$niri_sock
cage_sock=$(ls "$XDG_RUNTIME_DIR" | grep -E '^wayland-[0-9]+$' | grep -v "^$niri_sock$" | head -1)

# —— weston headless：flutter UI 窗口宿主（多客户端；应用重绘驱动帧回调）——
# 注意：不能用第二个 cage——cage 是单客户端 kiosk，只 map -s 启动的那个客户端，
# 后连接的 flutter 窗口永不 map → 无帧回调 → 无快照。
# weston headless 适合本场景：普通应用客户端自身 damage 驱动重绘
#（此前"weston 不能用"的结论只针对嵌套合成器场景）
weston --backend=headless-backend.so --socket=flutter-hd --width=400 --height=240 \
    --idle-time=0 >/tmp/weston-ui.log 2>&1 &
weston_pid=$!
for i in $(seq 1 30); do [ -S "$XDG_RUNTIME_DIR/flutter-hd" ] && break; sleep 0.5; done
cage2_sock=flutter-hd
if [ ! -S "$XDG_RUNTIME_DIR/flutter-hd" ]; then
    echo "!! weston 未启动："; tail -5 /tmp/weston-ui.log
fi
echo "cage1(niri)=$niri_sock weston(flutter)=$cage2_sock"

# —— fcitx5（VOICEINPUT_UI_DISPLAY 指向 cage2）——
export VOICEINPUT_UI_DISPLAY=$cage2_sock
fcitx5 -d --replace >/tmp/fcitx5.log 2>&1
/opt/dist/bin/testapp-gtk >/tmp/app.log 2>&1 &
for i in $(seq 1 40); do call State >/dev/null 2>&1 && break; sleep 0.5; done
sleep 2

# —— 录屏（对 cage1）——
date +%s.%N > /tmp/t-recorder
WAYLAND_DISPLAY=$cage_sock wf-recorder --no-dmabuf --codec libx264 -f /tmp/f4.mp4 >/tmp/wf.log 2>&1 &
REC=$!
sleep 1
date +%s.%N > /tmp/t-press

echo "== 触发录音（HoldRelease 4.5s）"
call SimulateKey Control_R true >/dev/null
sleep 1.2          # fA：录音 UI（含 partial）——popup 映射有 ~1s 延迟，取 3.9s 点
sleep 2.7          # fB：计时已走 + partial 续出
call SimulateKey Control_R false >/dev/null
date +%s.%N > /tmp/t-release
sleep 2.8          # 候选期（留足 niri map popup 的时间）
echo "state: $(call State)"
call SimulateKey Escape true >/dev/null
date +%s.%N > /tmp/t-esc
# 已知特性（niri）：静止应用不产生 damage，IM popup 区域重绘周期 ~3.4s，
# 故 hide 的清除效果最多滞后 ~3.5s 才上屏；真实打字场景应用持续 damage 无此问题
sleep 6.0
date +%s.%N > /tmp/t-end
echo "state: $(call State)（idle，popup 应隐藏）"

kill -INT $REC 2>/dev/null
sleep 2
kill %1 %2 %3 2>/dev/null

echo "=== 桥日志："
grep -aE "UiBridge" /tmp/fcitx5.log
echo "=== flutter 进程输出（尾10行）："
tail -10 /tmp/voiceinput-ui.log 2>/dev/null || echo "(无输出)"

# —— 断言：时间线对齐的全视频扫描（与实际帧率无关）——
python3 - <<'PYEOF'
import subprocess, sys

W, H = 1280, 720
t = {}
for k in ('recorder', 'press', 'release', 'esc', 'end'):
    t[k] = float(open(f'/tmp/t-{k}').read())

vis_counts = []
proc = subprocess.Popen(["ffmpeg", "-v", "error", "-i", "/tmp/f4.mp4",
    "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], stdout=subprocess.PIPE)
fs = W * H * 3
# 光亮面板检测：全屏扫（popup 位置由合成器决定——窗口居中时在光标下方，
# 贴顶时在上方，位置无关；基线相对判定排除 testapp 自身亮区）
def panel_count(buf):
    cnt = 0
    for y in range(30, 690, 12):
        base = y * W
        for x in range(100, 900, 12):
            i = (base + x) * 3
            if buf[i] > 195 and buf[i+1] > 195 and buf[i+2] > 195:
                cnt += 1
    return cnt
frames = []
while True:
    buf = proc.stdout.read(fs)
    if len(buf) < fs:
        break
    frames.append(buf)
    vis_counts.append(panel_count(buf))
N = len(frames)
fps = (N - 1) / (t['end'] - t['recorder'])

def sec2frame(s):
    return max(0, min(N - 1, int((s - t['recorder']) * fps)))

# 基线：触发前的检测计数（testapp 自身浅灰区有非零基线）
# 面板已缩小（录音态 280x104），阈值相应下调
f_pre = sec2frame(t['press'] - 0.4)
base = sorted(vis_counts[:max(3, f_pre - 2)])[len(vis_counts[:max(3, f_pre - 2)])//2]
TH = base + 60
def visible(i):
    return vis_counts[i] > TH

f_rel = sec2frame(t['release'])
f_esc = sec2frame(t['esc'])
f_post = sec2frame(t['end'] - 0.3)

# 1) 录音期可见：release 前 2.5s 至 release
rec_vis = [i for i in range(sec2frame(t['press'] + 2.5), f_rel) if visible(i)]
c1 = len(rec_vis) > 5
# 2) 录音期内容变化（计时/流式）
def bbox_diff(a, b):
    d = 0
    for y in range(30, 690, 6):
        base = y * W
        for x in range(100, 900, 6):
            i = (base + x) * 3
            d += abs(a[i]-b[i]) + abs(a[i+1]-b[i+1]) + abs(a[i+2]-b[i+2])
    return d
d2 = 0
if c1:
    a, b = rec_vis[0], rec_vis[-1]
    d2 = bbox_diff(frames[a], frames[b])
c2 = d2 > 3000
# 3) 候选期与录音期不同（取候选窗口内最大差异帧，避开重绘过渡帧）
d3 = 0
cand_vis = [i for i in range(f_rel + 2, f_esc) if visible(i)]
if c1 and cand_vis:
    anchor = frames[rec_vis[-1]]
    d3, _ = max((bbox_diff(anchor, frames[i]), i) for i in cand_vis)
c3 = d3 > 8000
# 4) idle 后隐藏（niri 销毁后重绘有 ~2s 滞后：只要求最后 8 帧不可见）
c4 = all(not visible(i) for i in range(N - 8, N))

print(f"帧数={N} fps={fps:.1f} 基线={base} 录音可见帧={len(rec_vis)} 候选可见帧={len(cand_vis)}")
print(f"1) 录音期UI可见: {'✓' if c1 else '✗'}")
print(f"2) 录音期内容变化(计时/流式): {'✓' if c2 else '✗'} diff={d2}")
print(f"3) 候选期UI切换: {'✓' if c3 else '✗'} diff={d3}")
print(f"4) idle后隐藏(末段): {'✓' if c4 else '✗'}")
ok = c1 and c2 and c3 and c4
print("F4 断言:", "全部通过 ✓" if ok else "未通过 ✗")
sys.exit(0 if ok else 1)
PYEOF
RC=$?
# 导出证据帧（固定索引：触发前/录音中/候选期）
ffmpeg -y -v error -i /tmp/f4.mp4 -vf "select=eq(n\,10)" -frames:v 1 /tmp/f4-f0.png 2>/dev/null
ffmpeg -y -v error -i /tmp/f4.mp4 -vf "select=eq(n\,150)" -frames:v 1 /tmp/f4-fA.png 2>/dev/null
ffmpeg -y -v error -i /tmp/f4.mp4 -vf "select=eq(n\,260)" -frames:v 1 /tmp/f4-fC.png 2>/dev/null
exit $RC
