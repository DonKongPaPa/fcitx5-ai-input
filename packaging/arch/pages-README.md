# fcitx5-ai-input pacman 仓库（x86_64）

fcitx5 语音输入：任意输入法激活时长按右 Ctrl 即说即上屏。
本仓库由 CI 随版本发布自动更新，包与元数据均经 GPG 签名
（钥指纹 `ABB4052808368FBEB41859420D91C18B512BAAD1`）。

## 一键安装（推荐）

```bash
curl -fsSL https://donkongpapa.github.io/fcitx5-ai-input/install.sh | sh
```

（想先过目脚本：把 `| sh` 换成 `| less`）

## 手动加仓库（每块一条，直接粘贴）

导入签名钥并本地签信任：

```bash
curl -fsSL https://donkongpapa.github.io/fcitx5-ai-input/repo-key.asc | sudo pacman-key --add -
```

```bash
sudo pacman-key --lsign-key ABB4052808368FBEB41859420D91C18B512BAAD1
```

写仓库配置：

```bash
sudo tee /etc/pacman.d/fcitx5-ai-input.conf <<'EOF'
[fcitx5-ai-input]
SigLevel = Required
Server = https://donkongpapa.github.io/fcitx5-ai-input/x86_64
CacheServer = https://github.com/DonKongPaPa/fcitx5-ai-input/releases/download/pacman-repo
EOF
```

```bash
echo 'Include = /etc/pacman.d/fcitx5-ai-input.conf' | sudo tee -a /etc/pacman.conf
```

安装：

```bash
sudo pacman -Syu fcitx5-ai-input
```

## 签名钥维护

仓库自带 `fcitx5-ai-input-keyring` 包（主包依赖它）：每次安装/升级自动把
最新签名钥导入 pacman keyring 并本地签信任（libalpm hook 跑
`pacman-key --populate`）。**换钥/轮换对仓库用户无感**——keyring 包先到，
签名随后切换。只有手动 `pacman -U` 不走仓库源的用户在换钥后需要重跑
一次上面的接入步骤。
