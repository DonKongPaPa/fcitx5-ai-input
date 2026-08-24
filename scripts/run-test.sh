#!/usr/bin/env bash
# 宿主机侧：单环境正式测试（容器内跑用例 → 生成 report.json/report.html）
# 用法：run-test.sh niri|kde|gnome
set -euo pipefail

ENV_NAME="${1:?用法: run-test.sh niri|kde|gnome}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="localhost/aiinput-${ENV_NAME}:latest"
RUN_ID="$(date +%Y%m%d-%H%M%S)-${ENV_NAME}"
OUT="$ROOT/artifacts/reports/$RUN_ID"
mkdir -p "$OUT"

# 依赖 dist 存在
if [ ! -d "$ROOT/artifacts/dist/lib/fcitx5" ]; then
    echo ">> artifacts/dist 不存在，先执行 make build"
    exit 1
fi

# sherpa 模型挂载（存在才挂；r15 用例无模型时自动跳过）。模型源目录
# 兼容新旧两代 fetch 脚本的下载位置（voiceinput 时代 → aiinput）
MODEL_ARGS=()
MODELS_SRC=""
for _d in "$HOME/.local/share/fcitx5-aiinput/models" \
          "$HOME/.local/share/fcitx5-voiceinput/models"; do
    if [ -d "$_d/sherpa-paraformer" ]; then MODELS_SRC="$_d"; break; fi
done
if [ -n "$MODELS_SRC" ]; then
    MODEL_ARGS=(-v "$MODELS_SRC:/models:ro")
fi

DEV_ARGS=()
for d in /dev/dri/renderD*; do
    if [ -e "$d" ]; then
        DEV_ARGS+=(--device "$d")
        break
    fi
done

T0=$(date +%s)
podman run --rm \
    --user 0 --userns=keep-id \
    "${DEV_ARGS[@]}" \
    -v "$ROOT/scripts:/scripts:ro" \
    -v "$ROOT/artifacts/dist:/opt/dist:ro" \
    -v "$ROOT/tests:/tests:ro" \
    -v "$ROOT/artifacts/voice-samples:/samples:ro" \
    "${MODEL_ARGS[@]}" \
    -v "$OUT:/out" \
    -e ENV_NAME="$ENV_NAME" \
    -e NIRI_TEST_SCALE="${NIRI_TEST_SCALE:-2.0}" \
    -e MODE=case \
    -e LOG_DIR=/out/logs \
    -e OUT_DIR=/out \
    -e CASES_DIR=/tests/cases \
    -e AIINPUT_SHERPA_MODEL_DIR=/models/sherpa-paraformer \
    "$IMAGE" \
    bash -c '
        set -e
        cp -r /opt/dist/* /usr/
        # 共存场景：普通输入法（keyboard-us）为默认 IM，aiinput 是
        # Module（全局热键），全程不切换输入法；pinyin 挂在组内供 r25
        # 切换（classicui 候选窗与我们的 popup 抢 smithay 定位槽的复现）
        mkdir -p /home/testuser/.config/fcitx5
        printf "[Groups/0]\nName=Default\nDefault Layout=us\nDefaultIM=keyboard-us\n\n[Groups/0/Items/0]\nName=keyboard-us\n\n[Groups/0/Items/1]\nName=pinyin\n\n[Group Order]\n0=Default\n" \
            > /home/testuser/.config/fcitx5/profile
        chown -R testuser:testuser /home/testuser/.config
        chown testuser:testuser /out /out/logs 2>/dev/null || true
        fcitx5 --version > /out/env-info.txt 2>&1 || true
        su testuser -c "dbus-run-session -- bash /scripts/env/start-${ENV_NAME}.sh"
    '
T1=$(date +%s)

python3 "$ROOT/scripts/report.py" "$RUN_ID" "$ENV_NAME" "$IMAGE" "$((T1 - T0))"

echo ">> 报告：$OUT/report.html"
