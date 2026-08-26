#!/usr/bin/env bash
# surface-test 驱动（容器内，sway 1080p）：单场景双引擎定位测量。
# 场景：布局窗口→聚焦→Trigger 预填（caret 可预测）→基线截图→
#   引擎 A=aiinput（长按触发，卡片出现）截图；
#   引擎 B=classicui（切 pinyin 组合 NIHAO，候选窗出现）截图；
# 每引擎：PIL 差分 bbox（基线 vs UI 截图，|ΔRGB|>15）+ journal 锚定日志
# 摘录 → HTML 并排报告 + 标注图（annotate.py，vision 探针素材）。
# 定位偏差根因分析时按 lab/surface/vision-probe.md 走 vision 二次测量。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

unset GTK_IM_MODULE QT_IM_MODULE SDL_IM_MODULE XMODIFIERS
SCENARIO="${SURFACE_SCENARIO:-S1}"
DIST_BIN="${DIST_BIN:-/opt/dist/bin}"
FCITX_LOG="$LOG_DIR/fcitx5.log"
call() { timeout 30 gdbus call --session --dest org.fcitx.Fcitx5 \
    --object-path /org/fcitx/AiInput \
    --method org.fcitx.AiInput.Test."$1" "${@:2}" 2>&1; }
trigger_text() { timeout 30 gdbus call --session --dest org.fcitx.Fcitx5 \
    --object-path /org/fcitx/AiInput \
    --method org.fcitx.AiInput.Test.Trigger "$1" >/dev/null 2>&1 || true; }
niri_act() { NIRI_SOCK_FILE="$(ls "$XDG_RUNTIME_DIR" | grep -m1 '^niri\.')"
    [ -n "$NIRI_SOCK_FILE" ] && NIRI_SOCKET="$XDG_RUNTIME_DIR/$NIRI_SOCK_FILE" \
        niri msg action "$1" >/dev/null 2>&1 || true; }
shot() { WAYLAND_DISPLAY="$CAGE_SOCK" timeout 10 grim "$1" 2>/dev/null || true; }
set_im() { timeout 30 gdbus call --session --dest org.fcitx.Fcitx5 \
    --object-path /controller \
    --method org.fcitx.Fcitx.Controller1.SetCurrentIM "$1" \
    >/dev/null 2>&1 || true; }

# —— 场景布局 ——
prefill_long="定位测量基准文本一二三四五六七八九十百千万亿甲乙丙丁"
case "$SCENARIO" in
S1) APP=gtk;  TEXT="基准文本";    LAYOUT=left ;;
S2) APP=gtk;  TEXT="$prefill_long"; LAYOUT=left ;;
S3) APP=gtk;  TEXT="基准文本";    LAYOUT=right ;;
S4) APP=qt;   TEXT="基准文本";    LAYOUT=max ;;
S5) APP=qt;   TEXT="基准文本";    LAYOUT=right ;;
S6) APP=chromium; TEXT="基准文本"; LAYOUT=left ;;
*) echo "未知场景 $SCENARIO"; exit 1 ;;
esac

launch_app() { # launch_app <tag>：按场景 app 类型启动
    case $APP in
    gtk) "$DIST_BIN/testapp-gtk" >"$LOG_DIR/app-$1.log" 2>&1 & ;;
    qt)  QT_IM_MODULE=fcitx "$DIST_BIN/testapp-qt" >"$LOG_DIR/app-$1.log" 2>&1 & ;;
    chromium)
        cat >/tmp/surf.html <<'HTML'
<!doctype html><html><body style="margin:0">
<input id="q" autofocus style="position:absolute;left:0;top:0;width:100%;height:100%;font-size:32px;border:8px solid #d00" placeholder="type here">
</body></html>
HTML
        chromium --ozone-platform=wayland --class=surf-e2e --enable-wayland-ime \
            --no-first-run --disable-gpu --no-sandbox --disable-dev-shm-usage \
            --user-data-dir="/tmp/chrome-surf-$1" file:///tmp/surf.html \
            >"$LOG_DIR/chromium-$1.log" 2>&1 & ;;
    esac
}

echo "== surface-test $SCENARIO（app=$APP layout=$LAYOUT）"
TAG="$SCENARIO"
launch_app a; sleep 2
if [ "$LAYOUT" = right ]; then
    launch_app b; sleep 2        # 第二窗口成右列
fi
if [ "$LAYOUT" = max ]; then niri_act maximize-column; sleep 1; fi

# 聚焦目标输入框：右列点右半屏（1920 输出，extent 1280x720 归一化）
case $LAYOUT in
left|max) CX=540; CY=80 ;;
right)   CX=1000; CY=80 ;;
esac
[ "$APP" = chromium ] && { CX=420; CY=400; sleep 8; }
timeout 10 "$DIST_BIN/virtpoint" move "$CX" "$CY" 1280 720 2>/dev/null || true
timeout 10 "$DIST_BIN/virtpoint" click left 2>/dev/null || true
sleep 0.8
MARK=$(wc -l < "$FCITX_LOG")
trigger_text "$TEXT"; sleep 1.5   # 预填：caret 落文本末尾

# —— 引擎 A：aiinput 语音卡 ——
shot "$OUT_DIR/${TAG}-baseline.png"
timeout 30 bash -c "echo ok" >/dev/null # noop 保持结构
timeout 60 bash -c '
  gdbus call --session --dest org.fcitx.Fcitx5 --object-path /org/fcitx/AiInput \
    --method org.fcitx.AiInput.Test.SimulateKey "Control+Control_R" true >/dev/null 2>&1
' || true
sleep 1.6
shot "$OUT_DIR/${TAG}-ours.png"
timeout 30 bash -c '
  gdbus call --session --dest org.fcitx.Fcitx5 --object-path /org/fcitx/AiInput \
    --method org.fcitx.AiInput.Test.SimulateKey "Control+Control_R" false >/dev/null 2>&1
' || true
sleep 2
call SimulateKey "Control+Control_R" true >/dev/null 2>&1 || true
sleep 0.3
call SimulateKey "Control+Control_R" false >/dev/null 2>&1 || true
sleep 1.5
OURSWIN="$(tail -n +$((MARK+1)) "$FCITX_LOG")"
printf '%s' "$OURSWIN" | grep -aE "text_input_rectangle|贴光标锚定|X OR 卡片窗|layer surface created|popup surface attached" \
    >"$OUT_DIR/${TAG}-ours-journal.txt" || true

# —— 引擎 B：classicui 候选窗 ——
MARK2=$(wc -l < "$FCITX_LOG")
shot "$OUT_DIR/${TAG}-baseline2.png"
set_im pinyin; sleep 0.6
for k in N I H A O; do
    timeout 15 gdbus call --session --dest org.fcitx.Fcitx5 \
        --object-path /org/fcitx/AiInput \
        --method org.fcitx.AiInput.Test.InjectKey "$k" true >/dev/null 2>&1 || true
    timeout 15 gdbus call --session --dest org.fcitx.Fcitx5 \
        --object-path /org/fcitx/AiInput \
        --method org.fcitx.AiInput.Test.InjectKey "$k" false >/dev/null 2>&1 || true
    sleep 0.25
done
sleep 1.2
shot "$OUT_DIR/${TAG}-classicui.png"
timeout 15 gdbus call --session --dest org.fcitx.Fcitx5 \
    --object-path /org/fcitx/AiInput \
    --method org.fcitx.AiInput.Test.InjectKey "Escape" true >/dev/null 2>&1 || true
timeout 15 gdbus call --session --dest org.fcitx.Fcitx5 \
    --object-path /org/fcitx/AiInput \
    --method org.fcitx.AiInput.Test.InjectKey "Escape" false >/dev/null 2>&1 || true
set_im keyboard-us
CLSWIN="$(tail -n +$((MARK2+1)) "$FCITX_LOG")"
printf '%s' "$CLSWIN" | grep -aE "text_input_rectangle|重夺定位槽|X OR" \
    >"$OUT_DIR/${TAG}-classicui-journal.txt" || true

# —— 测量与报告 ——
python3 - "$OUT_DIR" "$TAG" "$SCENARIO" "$APP" "$LAYOUT" <<'PYEOF'
import json, sys, subprocess
from pathlib import Path
from PIL import Image, ImageChops

out, tag, scen, app, layout = Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]

def diff_bbox(base, ui, thresh=15):
    a = Image.open(base).convert("RGB")
    b = Image.open(ui).convert("RGB")
    d = ImageChops.difference(a, b).convert("L")
    px = d.load()
    x0 = y0 = 10**9; x1 = y1 = -1
    for y in range(0, d.size[1], 2):
        for x in range(0, d.size[0], 2):
            if px[x, y] > thresh:
                x0 = min(x0, x); x1 = max(x1, x)
                y0 = min(y0, y); y1 = max(y1, y)
    if x1 < 0:
        return None
    return {"x": x0, "y": y0, "w": x1 - x0, "h": y1 - y0}

def caret_from_journal(p):
    t = p.read_text() if p.exists() else ""
    import re
    m = re.findall(r"text_input_rectangle (\d+),(\d+) (\d+)x(\d+)", t)
    return {"x": int(m[-1][0]), "y": int(m[-1][1]),
            "w": int(m[-1][2]), "h": int(m[-1][3])} if m else None

ours_bbox = diff_bbox(out/f"{tag}-baseline.png", out/f"{tag}-ours.png")
cls_bbox = diff_bbox(out/f"{tag}-baseline2.png", out/f"{tag}-classicui.png")
caret = caret_from_journal(out/f"{tag}-ours-journal.txt")

# 标注图（vision 探针素材：只画几何参考）
meta = {"windows": [], "caret": caret}
# 窗口线框几何：从截图边缘推断太脆——先留空，由根因分析时按 niri 布局补
(out/f"{tag}-meta.json").write_text(json.dumps(meta))
subprocess.run(["python3", "/lab/surface/annotate.py",
                str(out/f"{tag}-ours.png"), str(out/f"{tag}-meta.json"),
                str(out/f"{tag}-ours-annotated.png")], check=False)

report = {"scenario": scen, "app": app, "layout": layout, "caret": caret,
          "ours_bbox": ours_bbox, "classicui_bbox": cls_bbox,
          "note": "bbox=差分(|ΔRGB|>15)；caret=journal text_input_rectangle"
                  "（窗口局部系）；vision 二次测量见 lab/surface/vision-probe.md"}
(out/"surface-report.json").write_text(json.dumps(report, ensure_ascii=False, indent=1))

def box(b): return f"({b['x']},{b['y']} {b['w']}x{b['h']})" if b else "（无 UI 出现）"
html = f"""<!doctype html><meta charset="utf-8"><title>surface {scen}</title>
<body style="background:#222;color:#ddd;font-family:sans-serif">
<h2>surface-test {scen}（{app} / {layout} 列）</h2>
<p>caret（journal，窗口局部）：{box(caret)}　aiinput bbox：{box(ours_bbox)}　
classicui bbox：{box(cls_bbox)}</p>
<table><tr>
<td><h3>aiinput 卡片</h3><img src="{tag}-ours.png" width="640"></td>
<td><h3>classicui 候选窗</h3><img src="{tag}-classicui.png" width="640"></td>
</tr></table>
<h3>aiinput journal 摘录</h3><pre>{(out/f'{tag}-ours-journal.txt').read_text() if (out/f'{tag}-ours-journal.txt').exists() else '(无)'}</pre>
<h3>classicui journal 摘录</h3><pre>{(out/f'{tag}-classicui-journal.txt').read_text() if (out/f'{tag}-classicui-journal.txt').exists() else '(无)'}</pre>
</body>"""
(out/"surface-report.html").write_text(html)
print(json.dumps(report, ensure_ascii=False))
PYEOF
echo "== surface-test $SCENARIO 完成 → $OUT_DIR/surface-report.html"
