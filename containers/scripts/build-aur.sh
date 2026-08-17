#!/bin/sh
# 在镜像内从 AUR 构建包（运行时需要，容器内以 root 执行 makepkg 需切换用户）
set -eu

pkg="$1"
useradd -m aur 2>/dev/null || true

cat > /tmp/aur-build.sh <<EOF
set -eu
cd /tmp
git clone --depth=1 https://aur.archlinux.org/${pkg}.git
cd ${pkg}
makepkg -sf --noconfirm --skippgpcheck
EOF
chmod +x /tmp/aur-build.sh
su aur -c /tmp/aur-build.sh
pacman -U --noconfirm /tmp/${pkg}/*.pkg.tar.zst
rm -rf /tmp/${pkg} /tmp/aur-build.sh
