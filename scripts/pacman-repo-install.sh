#!/bin/sh
# fcitx5-ai-input pacman 仓库安装器（发布时改名为 install.sh 放 Pages 根）。
# 写仓库配置 + 导入签名钥 + 安装；幂等——重复运行即更新到最新。
# 只动 /etc/pacman.conf（先备份）与 /etc/pacman.d/fcitx5-ai-input.conf。
set -eu

REPO=fcitx5-ai-input
PKG=fcitx5-ai-input
# 指纹硬编码：下载到的仓库公钥必须与之匹配才导入（防托管面被换钥）
FINGERPRINT=ABB4052808368FBEB41859420D91C18B512BAAD1
SERVER=${AIINPUT_REPO_SERVER:-https://donkongpapa.github.io/fcitx5-ai-input}
CACHE_SERVER=${AIINPUT_REPO_CACHE_SERVER:-https://github.com/DonKongPaPa/fcitx5-ai-input/releases/download/pacman-repo}

case "${1:-}" in
  --help|-h)
    printf 'Usage: sh install.sh\n添加 fcitx5-ai-input pacman 仓库（GPG 签名）并安装/更新。\n'
    exit 0 ;;
  '') ;;
  *) printf '未知参数: %s\n' "$1" >&2; exit 1 ;;
esac
[ "$(uname -m)" = x86_64 ] || { echo '需要 x86_64 架构。' >&2; exit 1; }
command -v pacman >/dev/null || { echo '需要 Arch Linux（有 pacman）。' >&2; exit 1; }
command -v curl >/dev/null || { echo '需要 curl。' >&2; exit 1; }
command -v gpg >/dev/null || { echo '需要 gpg。' >&2; exit 1; }

as_root() {
  if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
}

config=/etc/pacman.conf
include=/etc/pacman.d/$REPO.conf
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM

# 1. 公钥：下载 → 指纹匹配才导入并本地签信任（pacman-key）
curl -fsSL "$SERVER/repo-key.asc" -o "$tmpdir/repo-key.asc"
fpr=$(gpg --show-keys --with-colons "$tmpdir/repo-key.asc" | awk -F: '/^fpr/{print $10; exit}')
if [ "$fpr" != "$FINGERPRINT" ]; then
    echo "仓库公钥指纹不匹配（${fpr:-空}），中止。" >&2
    exit 1
fi
as_root pacman-key --init 2>/dev/null || true  # 未初始化的系统兜底；已初始化时幂等
as_root pacman-key --add "$tmpdir/repo-key.asc"
as_root pacman-key --lsign-key "$FINGERPRINT"

# 2. 仓库配置片段（值必须与本脚本常量一致，冲突时拒绝覆盖）
fragment=$tmpdir/fragment.conf
cat > "$fragment" <<EOF
[$REPO]
# fcitx5-ai-input pacman 仓库（GPG 签名，钥指纹 $FINGERPRINT）
SigLevel = Required
Server = $SERVER/x86_64
CacheServer = $CACHE_SERVER
EOF

if pacman-conf --repo-list | grep -qx "$REPO"; then
    if [ ! -f "$include" ] || [ "$(cat "$fragment")" != "$(cat "$include")" ] || \
       ! grep -qxF "Include = $include" "$config"; then
        echo "已有不一致的 $REPO 仓库配置，请先人工检查 $config 与 $include。" >&2
        exit 1
    fi
fi
printf '%s\n' '将添加 fcitx5-ai-input 仓库（GPG 签名包）。需要管理员权限写 pacman 配置。' \
    'pacman 会在安装/升级前给出确认提示。'
as_root install -m 644 "$fragment" "$include"
if ! grep -qxF "Include = $include" "$config"; then
    as_root cp -p "$config" "$config.aiinput.bak"
    printf '\nInclude = %s\n' "$include" | as_root tee -a "$config" >/dev/null
fi

# 3. 完整升级避免部分升级；--needed 幂等；保留 pacman 确认提示
as_root pacman -Syu --needed "$PKG"
echo '完成。任意输入法激活时长按右 Ctrl 即语音输入；更新随 pacman -Syu 自动到达。'
