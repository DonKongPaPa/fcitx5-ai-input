#!/usr/bin/env bash
# 容器套件编排（宿主侧）：scale 矩阵 + 报告
# 用法：
#   make test ENV=niri                  # 双 scale 矩阵（1.0 正常 + 2.0 放大）
#   NIRI_TEST_SCALE=1.5 make test ...   # 只跑单档
#   SUITE=smoke make test ...           # 只跑部署后运行检查（5 例）
#   SCALE_MATRIX="2.0" make test ...    # 自定义矩阵
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_NAME="${1:?用法: run-test.sh niri|kde|gnome}"
IMAGE="localhost/aiinput-${ENV_NAME}:latest"

if [ ! -d "$ROOT/artifacts/dist/lib/fcitx5" ]; then
    echo "!! 先跑 make build（artifacts/dist 缺失）"
    exit 1
fi

# 模型可选挂载（启用真实引擎用例）
MODEL_ARGS=()
for _d in "$HOME/.local/share/fcitx5-aiinput/models" \
          "$HOME/.local/share/fcitx5-voiceinput/models"; do
    if [ -d "$_d/sherpa-paraformer" ]; then
        MODEL_ARGS+=(-v "$_d:/models:ro")
        break
    fi
done

# 直通宿主机 GPU 渲染节点（只传第一个）：
# - 传多个渲染节点会导致 wlroots(cage/sway) 跨 GPU dmabuf 拷贝失败
#   （双显卡机器上 NVIDIA 节点参与时 screencopy 报 Failed to copy frame）
# - kwin 用 KWIN_COMPOSE=Q 软件渲染后不再强求第二个节点
DEV_MODE="${DEV_MODE:-first}"
DEV_ARGS=()
for d in /dev/dri/renderD*; do
    [ -e "$d" ] || continue
    DEV_ARGS+=(--device "$d")
    [ "$DEV_MODE" = "first" ] && break
done

# scale 矩阵：默认两轮（1.0=正常 + 2.0=放大，1080p 输出）；NIRI_TEST_SCALE
# 显式指定则只跑该档。每轮独立 run_id（时间戳自然错开）+ 独立报告
if [ -n "${NIRI_TEST_SCALE:-}" ]; then
    SCALES="$NIRI_TEST_SCALE"
else
    SCALES="${SCALE_MATRIX:-1.0 2.0}"
fi

for SCALE in $SCALES; do
    RUN_ID="$(date +%Y%m%d-%H%M%S)-${ENV_NAME}"
    OUT="$ROOT/artifacts/reports/$RUN_ID"
    mkdir -p "$OUT/logs"
    T0=$(date +%s)
    echo ">> scale=$SCALE → $OUT"
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
        -e NIRI_TEST_SCALE="$SCALE" \
        -e MODE=case \
        -e SUITE="${SUITE:-all}" \
        -e LOG_DIR=/out/logs \
        -e OUT_DIR=/out \
        -e CASES_DIR=/tests/cases \
        -e AIINPUT_SHERPA_MODEL_DIR=/models/sherpa-paraformer \
        "$IMAGE" \
        bash -c '
            set -e
            # Qt 的 QDBusConnection 读 /etc/machine-id，缺失时 Qt 应用启动即
            # abort——c5 的 DBus 前端 IC（QT_IM_MODULE=fcitx，DMS 同型）需要
            [ -s /etc/machine-id ] || printf "%s\n" "$(cat /proc/sys/kernel/random/uuid | tr -d -)" > /etc/machine-id
            cp -r /opt/dist/* /usr/
            # 共存场景：普通输入法（keyboard-us）为默认 IM，aiinput 是
            # Module（全局热键），全程不切换输入法；pinyin 挂在组内供 c7/c8
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
    echo ">> 报告：$OUT/report.html（scale=$SCALE）"
done
