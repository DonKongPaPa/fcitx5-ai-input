#!/usr/bin/env bash
# F6 编排（全容器形态）：funasr-gpu 容器 → niri 容器 f6 → 销毁
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/artifacts/f6"
mkdir -p "$OUT"

bash "$ROOT/scripts/funasr-container.sh" start-gpu
echo -n "等待 GPU 容器就绪… "
for _ in $(seq 1 120); do
    if [ -n "$(podman logs funasr-gpu 2>&1 | grep -a 'listening on')" ]; then echo ok; break; fi
    sleep 1
done

DEV_ARGS=()
for d in /dev/dri/renderD*; do
    [ -e "$d" ] && DEV_ARGS+=(--device "$d") && break
done
EXP="$ROOT/experiments/001-funasr-nano-local"
timeout 300 podman run --rm \
    --user 0 --userns=keep-id "${DEV_ARGS[@]}" \
    --network voiceinput-net \
    -v "$ROOT/scripts:/scripts:ro" \
    -v "$ROOT/artifacts/dist:/opt/dist:ro" \
    -v "$ROOT/artifacts/voice-samples:/samples:ro" \
    -v "$EXP/data/llamacpp:/usr/lib/fcitx5-voiceinput/llamacpp:ro" \
    -v "$EXP/data/gguf:/usr/lib/fcitx5-voiceinput/gguf:ro" \
    -v "$OUT:/out" \
    localhost/voiceinput-niri:latest \
    bash -c '
        cp -r /opt/dist/* /usr/ || true
        mkdir -p /tmp/dbus-masked
        mv /usr/share/dbus-1/services/org.fcitx.Fcitx5.service /tmp/dbus-masked/ 2>/dev/null || true
        mkdir -p /home/testuser/.config/fcitx5
        printf "[Groups/0]\nName=Default\nDefault Layout=us\nDefaultIM=voiceinput\n\n[Groups/0/Items/0]\nName=voiceinput\nLayout=\n\n[Group Order]\n0=Default\n" > /home/testuser/.config/fcitx5/profile
        chown -R testuser:testuser /home/testuser/.config
        chown testuser:testuser /out 2>/dev/null || true
        su testuser -c "dbus-run-session -- bash /scripts/env/f6-test.sh" > /tmp/f6-out.log 2>&1 || true
        cp /tmp/f6.mp4 /tmp/fcitx5.log /tmp/app-events.jsonl /tmp/f6-out.log /tmp/voiceinput-ui.log /out/ 2>/dev/null || true
        chmod 644 /out/* 2>/dev/null || true
        kill -9 -1 2>/dev/null || true
    ' >/dev/null 2>&1
grep -aE "✓|✗|F6 结果|全部通过|存在失败" "$OUT/f6-out.log" | tail -28
podman rm -fa >/dev/null 2>&1 || true
bash "$ROOT/scripts/funasr-container.sh" stop
