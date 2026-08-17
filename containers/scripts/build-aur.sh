#!/bin/sh
# 在镜像内从 AUR 构建包（curl 下载快照，不依赖 git；以 aur 用户执行 makepkg）
set -eu

pkg="$1"
useradd -m aur 2>/dev/null || true

cat > /tmp/aur-build.sh <<EOF
set -eu
cd /tmp
curl -fsSL -o ${pkg}.tar.gz "https://aur.archlinux.org/cgit/aur.git/snapshot/${pkg}.tar.gz"
tar xzf ${pkg}.tar.gz
cd ${pkg}
makepkg -sf --noconfirm --skippgpcheck
EOF
chmod +x /tmp/aur-build.sh
su aur -c /tmp/aur-build.sh
pacman -U --noconfirm /tmp/${pkg}/*.pkg.tar.zst
rm -rf /tmp/${pkg} /tmp/${pkg}.tar.gz /tmp/aur-build.sh
