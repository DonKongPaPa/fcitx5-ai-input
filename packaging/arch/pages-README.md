# fcitx5-ai-input pacman 仓库（x86_64）

fcitx5 语音输入：任意输入法激活时长按右 Ctrl 即说即上屏。
本仓库由 CI 随版本发布自动更新，包与元数据均经 GPG 签名
（钥指纹 `ABB4052808368FBEB41859420D91C18B512BAAD1`）。

## 一键接入（推荐）

```sh
curl -fsLo /tmp/aiinput-install.sh https://donkongpapa.github.io/fcitx5-ai-input/install.sh
less /tmp/aiinput-install.sh   # 先过目再跑
sh /tmp/aiinput-install.sh
```

## 手动接入

1. 导入签名钥并本地签信任：

```sh
curl -fsSL https://donkongpapa.github.io/fcitx5-ai-input/repo-key.asc | sudo pacman-key --add -
sudo pacman-key --lsign-key ABB4052808368FBEB41859420D91C18B512BAAD1
```

2. 在 `/etc/pacman.conf` 末尾追加：

```ini
[fcitx5-ai-input]
SigLevel = Required
Server = https://donkongpapa.github.io/fcitx5-ai-input/x86_64
CacheServer = https://github.com/DonKongPaPa/fcitx5-ai-input/releases/download/pacman-repo
```

3. `sudo pacman -Syu fcitx5-ai-input`（之后随 `-Syu` 自动更新）

## 签名钥维护

仓库自带 `fcitx5-ai-input-keyring` 包（主包依赖它）：每次安装/升级自动把
最新签名钥导入 pacman keyring 并本地签信任（libalpm hook 跑
`pacman-key --populate`）。**换钥/轮换对仓库用户无感**——keyring 包先到，
签名随后切换。只有不走仓库源、手动 `pacman -U` 的用户在换钥后需要重跑
一次上面的接入步骤。
