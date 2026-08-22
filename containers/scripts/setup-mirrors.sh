#!/bin/sh
# 镜像初始化：换中国 pacman 源 + 恢复被官方镜像 NoExtract 裁掉的 locale 数据
set -eu

# 1) 中国镜像源（TUNA 主、USTC 备）
cat > /etc/pacman.d/mirrorlist <<'EOF'
# Managed by fcitx5-ai-input build
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinux/$repo/os/$arch
Server = https://mirrors.ustc.edu.cn/archlinux/$repo/os/$arch
EOF

# 2) 官方 archlinux 镜像的 pacman.conf 裁掉了 usr/share/i18n/*（除英文），
#    删除 NoExtract 行，让后续安装/重装能拿到完整数据
sed -i '/^NoExtract/d' /etc/pacman.conf

echo "镜像源与 pacman.conf 已配置"
