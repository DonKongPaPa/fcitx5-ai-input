# fcitx5-ai-input

Linux 语音输入，长在 fcitx5 里：**按住右 Ctrl 说话，松开出字**。任何输入法激活时都能用（rime / 拼音 / 键盘英语，无需切换），识别文本直接落在光标处。悬浮卡片由 Flutter 渲染，进程内嵌入 fcitx5，无独立窗口、无独立进程。

```
[按住右 Ctrl 说话]
      ↓
[fcitx5 addon 状态机] ── 拦截触发键（PreInputMethod，输入法引擎之前）
      ├─ ASR 引擎（configtool 热切换）
      │    · Sherpa       CPU 流式（RSS ~412MB / 首字 ~0.07s / 0 显存）
      │    · FunASR       WS 流式（宿主服务，31 语种，GPU/CPU）
      │    · FunASRLocal  GGUF 本地（zh/en/ja 非流式，CPU ~1.5G）
      │    · Dummy        调试用确定性输出
      ├─ 流式 partial 实时进卡片 + 应用组合文本（跟随光标）
      └─ Flutter UI（raw embedder 进程内软渲染）
           ↓ wl_shm → zwp_input_popup_surface_v2（光标跟随）
识别完成 → 候选（润色/原始）→ 数字键/方向键/鼠标选择 → commitString 上屏
```

## 特性

- **与任意输入法共存**：模块级 addon（不注册输入法条目），触发键在引擎之前拦截，其余按键照常进入当前输入法
- **按住说话 / Toggle 两种触发模式**，长按阈值可调；录音中 Esc 取消
- **流式出字**：识别中间结果实时显示，无需等说完
- **光标跟随卡片**：悬浮卡片跟随输入光标（GTK/Qt/Chromium/Electron 均可）；无法跟随时回落屏幕底部居中
- **候选修正**：识别结果先进候选框（数字 1-9 / 方向键 / Enter / 鼠标 hover+点击 选择），Esc 取消
- **多引擎档**：内置 sherpa-onnx CPU 流式（零显存、模型脚本下载）；可选 FunASR 服务档（31 语种）与 GGUF 本地档
- **fractional scale**：混缩放多屏下卡片按真实缩放渲染物理帧，不模糊不错位

## 安装

 Releases 页下载对应发行版包（或从源码构建，见[贡献指南](CONTRIBUTING.md)）：

```bash
# Arch
pacman -U fcitx5-ai-input-*.pkg.tar.zst
# Debian
apt install ./fcitx5-ai-input_*.deb
# Fedora
dnf install fcitx5-ai-input-*.rpm
# 其他（需 gcc/cmake/fcitx5-dev/wayland-dev/fontconfig-dev）
tar xf fcitx5-ai-input-*.tar.* && cd fcitx5-ai-input-* && sudo bash install.sh
```

安装后重启 fcitx5 即生效（模块自动加载，无需添加输入法）。

使用内置 Sherpa 引擎（推荐，零显存）需下载模型（~200MB，sha256 锁定）：

```bash
sudo bash /usr/lib/fcitx5-aiinput/scripts/fetch-sherpa-runtime.sh   # 运行时库（首次）
bash /usr/lib/fcitx5-aiinput/scripts/fetch-sherpa-models.sh         # 模型 → ~/.local/share/fcitx5-aiinput/models/
# 可选：SenseVoice 松手重识别（中英混说/标点质量更好）
bash /usr/lib/fcitx5-aiinput/scripts/fetch-sherpa-models.sh --model sensevoice
```

## 使用

1. 任意输入框获得焦点（任意输入法状态）
2. **按住右 Ctrl** 开始说话（超过长按阈值，默认 300ms；Toggle 模式则再按一次结束）
3. 卡片实时显示识别中间结果，并跟随光标移动
4. 松开：直接上屏（默认），或进候选框选择（LLM 引擎非 Off 时）
   - 候选态：`1-9` 选对应项 / `↑↓←→` 换行 / `Enter` 选首项 / `Esc` 取消
   - 鼠标：hover 高亮 + 点击选择
5. 录音中 `Esc` / `Backspace` 取消整轮（候选/结果态同义）

所有行为可在 `fcitx5-configtool → 插件 → Voice Input` 中配置，保存即生效（无需重启）。

## 配置速览

| 配置 | 默认 | 说明 |
|---|---|---|
| TriggerKeys | 右 Ctrl | 触发键（支持组合，可多条） |
| TriggerMode | HoldRelease | 按住说话 / Toggle |
| TriggerThresholdMs | 300 | 长按阈值 |
| AsrEngine | Dummy | Dummy / Sherpa / FunASR / FunASRLocal |
| PositionMode | auto | auto=可跟随则跟随否则底部居中 / caret=强制跟随 / bottom / top |
| PositionFallbackApps | （空） | 强制底部居中的应用名单（程序名子串匹配） |
| DbusPosition | follow | DBus 前端应用（GTK/QT_IM_MODULE=fcitx，如 DMS 启动器、WPS）的卡片定位：follow=贴光标矩形 / bottom=底部居中 |
| UIFont | （空） | 卡片字体（Pango 串；空=跟随 classicui 字体） |
| LLMEngine | Dummy | LLM 引擎：Dummy=占位润色（规则补标点，双行候选）/ Off=关闭（结果直接上屏）；真实双后端接入中 |
| UiAnimSpeed | 慢速 | 卡片动画速率挡位（慢速/标准/快速，缩放全部过渡动画时长） |
| PopupTimeoutMs | 1500 | 无候选时结果停留时长 |

FunASR 服务档：configtool「模型部署」组配置 `FunASRAutoStart` + `FunASRServerCmd`（指向 `funasr-serve.sh`），连接失败自动拉起；或手动 `scripts/funasr-serve.sh start`。

## 定位机制（为什么能跟随光标）

- 卡片挂在 waylandim 的 `zwp_input_method_v2` 连接上（协议规定一个 seat 只有一个 IM，必须复用，不能自建），popup 的定位权在合成器：按 text-input 光标矩形放置
- popup 生命周期照抄 classicui：每次显示销毁重建（重夺合成器的单槽追踪 + 继承最新矩形），隐藏即 unmap+销毁
- Chromium/Electron 只在**文本变化时**上报光标矩形（焦点时不报）：录音开始即向应用打入可见组合文本探针（「语音输入中」逐字），组合变化逼应用重报矩形，流式识别文本接续灌入组合——卡片全程贴住光标
- 无人报矩形的应用（或判定到录音结束仍无矩形）：layer-shell 底部居中兜底
- D-Bus 前端的应用（`GTK_IM_MODULE/QT_IM_MODULE=fcitx`，如 DMS 启动器）：IC 不经 waylandim、跟随路径整体不可达 → overlay 层卡片兜底，预编辑「语音输入中」经 D-Bus 照常送达应用
- `DbusPosition=follow`（默认）时 overlay 卡片贴光标：光标矩形是应用窗口局部坐标，对铺满输出的窗口（DMS 单窗 spotlight、整列平铺/最大化的 WPS 等——实测占绝对多数）即输出绝对坐标，直接可用；矩形变化（`InputContextCursorRectChanged`）与卡片尺寸变化都会实时重锚（下方放不下翻到光标上方、水平钳入输出）。部分可见（半宽平铺/浮动）窗口会有窗口原点偏移——Wayland 不暴露其它 surface 位置，best effort

## 开发与测试

```bash
make images              # 构建 podman 测试镜像（base/host/build/niri/kde/gnome）
make build               # 容器内编译 addon + Flutter 资产 + 测试应用
make test ENV=niri       # 34 例容器套件（录屏 + journal 断言 + 报告）
```

测试体系（无头合成器容器矩阵、真实音频样本、报告与基准对照）、新增用例方法、容器踩坑与验证纪律见 **[CONTRIBUTING.md](CONTRIBUTING.md)**。

## 已知限制

- 无矩形上报且录音极短的场景，卡片首次出现在底部（跟随判定无解时兜底，非缺陷）
- LLM 润色当前为 Dummy 占位档（规则补标点，可在 configtool 切 Off 关闭候选直接上屏），双后端接入开发中
- kwin / gnome-shell 环境跑过冒烟，定位链路以 niri/GNOME（mutter）验证最充分

## License

MIT
