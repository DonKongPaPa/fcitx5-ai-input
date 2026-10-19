#!/usr/bin/env bash
# Arch 打包（archlinux:base-devel 容器内运行）：
#   装依赖 → stage → 手工组 .pkg.tar.zst（.PKGINFO，pacman -U 兼容，
#   免 makepkg 的 root/fakeroot 纠缠）→ 安装 → 冒烟
# 注意：脚本内禁止对 /work 做任何 chown（rootless 容器的 chown 会把
# 宿主文件改成 subuid 属主，夺走宿主写权限——踩过）
set -euo pipefail
SRC="${SRC:-/work}"
VERSION="${VERSION:-0.1.0}"
export SRC VERSION

# 国内源 opt-in（本地容器构建用；CI 不设此变量走官方源）
if [ "${AIINPUT_CN_MIRROR:-0}" = 1 ] && ! grep -q tuna /etc/pacman.d/mirrorlist 2>/dev/null; then
    printf 'Server = https://mirrors.tuna.tsinghua.edu.cn/archlinux/$repo/os/$arch\n' > /etc/pacman.d/mirrorlist
fi

pacman -Syu --noconfirm --needed cmake gcc wayland fontconfig fcitx5 libpulse dbus zstd \
    >/dev/null 2>&1 || { echo "!! 依赖安装失败"; exit 1; }
pacman -Scc --noconfirm >/dev/null 2>&1 || true

bash "$SRC/packaging/common/stage.sh"

STAGE="$SRC/packaging/out/stage"
PKG="$SRC/artifacts/packages/fcitx5-ai-input-$VERSION-1-x86_64.pkg.tar.zst"
mkdir -p "$SRC/artifacts/packages"

# —— keyring 包：仓库签名钥的常规分发渠道。install.sh 只做首次引导导入；
#    此后换钥/吊销随本包升级（PostTransaction hook 跑 pacman-key --populate）
#    自动到达，用户无需任何手动步骤。
KEYRING_VER="${KEYRING_VER:-20261019}"
KEYRING_PKG="$SRC/artifacts/packages/fcitx5-ai-input-keyring-$KEYRING_VER-1-any.pkg.tar.zst"
KSTAGE="$SRC/packaging/out/keyring-stage"
rm -rf "$KSTAGE"
mkdir -p "$KSTAGE/usr/share/pacman/keyrings" "$KSTAGE/usr/share/libalpm/hooks"
# 注意：绝不能把吊销证书打进 keyring（否则全网视钥为已吊销）——.rev 只离线备份
gpg --dearmor --output "$KSTAGE/usr/share/pacman/keyrings/fcitx5-ai-input.gpg" \
    "$SRC/packaging/arch/repo-key.asc"
install -m 644 "$SRC/packaging/arch/fcitx5-ai-input-keyring.hook" \
    "$KSTAGE/usr/share/libalpm/hooks/fcitx5-ai-input-keyring.hook"
cd "$KSTAGE"
{
    echo "pkgname = fcitx5-ai-input-keyring"
    echo "pkgver = $KEYRING_VER-1"
    echo "pkgdesc = PGP keys for the fcitx5-ai-input pacman repository"
    echo "url = https://github.com/DonKongPaPa/fcitx5-ai-input"
    echo "builddate = $(date +%s)"
    echo "packager = CI <ci@invalid>"
    echo "size = $(du -sb "$KSTAGE" | cut -f1)"
    echo "arch = any"
    echo "license = MIT"
} > .PKGINFO
tar --zstd -cf "$KEYRING_PKG" .PKGINFO usr
rm .PKGINFO
echo ">> 产物: $KEYRING_PKG ($(du -h "$KEYRING_PKG" | cut -f1))"

cd "$STAGE"
{
    echo "pkgname = fcitx5-ai-input"
    echo "pkgver = $VERSION-1"
    echo "pkgdesc = Fcitx5 voice input: sherpa-onnx streaming ASR (FunASR/GGUF tiers) + Flutter MD3 cursor-following card"
    echo "url = https://github.com/DonKongPaPa/fcitx5-ai-input"
    echo "builddate = $(date +%s)"
    echo "packager = CI <ci@invalid>"
    echo "size = $(du -sb "$STAGE" | cut -f1)"
    echo "arch = x86_64"
    echo "license = MIT"
    echo "depend = fcitx5"
    echo "depend = libpulse"
    echo "depend = fcitx5-ai-input-keyring"
} > .PKGINFO
tar --zstd -cf "$PKG" .PKGINFO usr
rm .PKGINFO
echo ">> 产物: $PKG ($(du -h "$PKG" | cut -f1))"

# 安装 + 冒烟（同事务装两包满足依赖；顺带实证 keyring hook 的 populate）
pacman-key --init >/dev/null 2>&1 || true
pacman -U --noconfirm "$KEYRING_PKG" "$PKG" >/dev/null
test -f /usr/share/pacman/keyrings/fcitx5-ai-input.gpg
pacman-key --list-keys fcitx5-ai-input | grep -q '\[full\]'
bash "$SRC/packaging/common/smoke.sh"
