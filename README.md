# fcitx5-voice-input

基于 fcitx5 的语音输入法：ASR 识别语音，LLM 优化输出结果（标点、纠错、分段），文本提交到光标处。

## 总体架构

```
[触发键 右Ctrl] → [fcitx5 C++ addon：状态机/配置/引擎抽象]
                      │
                      ├─ ASR 引擎三档（configtool 可切，热改即时生效）：
                      │   · FunASR（WS 流式档）：parec 采音 → 手写 WS 客户端
                      │     → 宿主 funasr-serve（MLT 31 语种，GPU 原生无容器，
                      │     累积窗口流式：每 720ms 全量重识别 + 剪尾）
                      │   · FunASRLocal（GGUF 本地档）：录音落盘 wav →
                      │     llama-funasr-cli 子进程（zh/en/ja 非流式，CPU ~1.5G）
                      │   · Dummy（调试/管线确定性回归）
                      │
                      │ TCP 127.0.0.1（行式 JSON 状态 + RGBA 帧）
                      ▼
              [Flutter voice_ui：MD3 浮窗，跑在 weston headless 上]
                RepaintBoundary.toImage 快照 → 帧回传
                      │
                addon: wl_shm buffer → wl_surface
                      → zwp_input_popup_surface_v2（借 waylandim 的 IM 连接，
                        合成器自动定位光标附近，同 classicui）
                      → 文本经 InputContext::commitString 落到光标处
```

- `addon/`：fcitx5 插件。配置（`voiceinput.conf.desc` → configtool 设置页，热改即时生效）、按键状态机（HoldRelease/Toggle 两模式 + 阈值 + 录音中 Esc 取消）、AsrEngine 抽象（Dummy/FunASR WS/FunASR GGUF 三实现）、UiBridge（flutter 进程管理 + 帧接收）、VoicePopup（popup surface，纯 C libwayland）
- `flutter/`：MD3 三态 UI（录音=mic+计时+流式 partial 尾部优先 / 结果 / 候选），全官方组件，自适应尺寸（宽 280–420 实测），快照帧桥
- `scripts/funasr-server/`：宿主 WS 识别服务（uv venv python3.12 + funasr/torch-CUDA，`scripts/funasr-serve.sh start` 管理）
- 定位不由我们计算：popup 挂在 waylandim 的 `zwp_input_method_v2` 上，合成器按 text-input 光标矩形放置（协议规定一个 seat 仅一个 IM，必须复用 waylandim 的连接，不能自 bind）

## 测试环境（一个桌面 = 一个独立容器）

无头方案：**wlroots 无头宿主合成器（sway/cage）托管被测合成器嵌套运行**，录屏统一走宿主的 wlr-screencopy（画面即被测合成器输出）。

| 容器镜像 | 被测合成器 | 无头宿主 | 说明 |
|---|---|---|---|
| `voiceinput-niri` | niri | cage(wlroots) | niri 不支持 headless（niri-wm#714），嵌套运行 |
| `voiceinput-kde` | kwin_wayland | sway(wlroots) | `KWIN_COMPOSE=Q` 软件渲染（容器嵌套 GL 起不来） |
| `voiceinput-gnome` | gnome-shell→mutter 嵌套 | sway(wlroots) | gnome-shell 嵌套需 logind session，自动回退裸 mutter |

- 镜像层级：`voiceinput-base`（Arch + 中国镜像源 + 公共栈）→ `voiceinput-host`（sway/cage + 补丁版 wf-recorder）→ 各桌面
- `voiceinput-build`：编译链 + Flutter SDK（flutter-io.cn 中国镜像）；`voiceinput-funasr`：FunASR 运行时（按需构建）
- **管线测试用确定性触发（D-Bus 直达 addon），不依赖真实 ASR/LLM**；真实引擎手动测试

### 踩坑记录（容器无头桌面）

- kwin/sway 自带 `cap_sys_nice` filecap → rootless 容器 exec EPERM → 镜像内 `setcap -r`
- 双 GPU 机器只直通第一个渲染节点：NVIDIA 节点参与会跨设备 dmabuf 拷贝失败
- wf-recorder 0.6.0 两个补丁（`containers/patches/`）：ffmpeg 9 API 适配（Arch 官方）+ dmabuf 绑定版本协商
- weston headless 是 no-op 渲染器不驱动帧时钟，不能当无头宿主用（但可以当 flutter 这类普通应用客户端的窗口宿主，应用自身 damage 驱动重绘）
- niri 26.04 的 KDL 解析不接受旧版单行内联 `animations { workspace-switch { off } }` 写法（解析失败静默回退默认配置 + 弹错误提示窗）
- 测试环境不设 `GTK_IM_MODULE`：应用必须走原生 text-input-v3（frontend=wayland_v2）才有 IM 激活与光标矩形；设 `=fcitx` 会走 dbus 前端，popup 取不到 IM proxy

## 使用

```bash
make images              # 构建全部镜像
make build               # 编译 addon / flutter / testapp → artifacts/dist/
make test ENV=niri       # 单环境测试（kde / gnome 同理），输出报告
make test-all            # 依次跑三个独立容器
make shell ENV=niri      # 进入指定环境容器交互调试
make baseline ENV=niri   # 将当前通过用例的录屏存为本地基准
make report RUN_ID=xxx   # 重新渲染报告
make compare             # 汇总历史报告，生成方案对比页（性能/干扰评估）
```

## 测试资产：真实语音样本

`语音测试集/`（**不进 git**，用户真实录音）：`中文测试.flac` / `英语测试.flac`，各约 6.3–6.5s（44.1kHz 立体声 FLAC）。

- 派生 16kHz 单声道 wav 副本在 `artifacts/voice-samples/`（`make` 外手动转换，同样不进 git），FunASR 引擎接入里程碑直接可用作识别输入
- 真实音频 E2E（录音→虚拟麦→ASR→候选→落点）属于 FunASR 接入里程碑；当前管线用 Dummy 引擎确定性驱动，长文本场景（f5 S7）的字数规模已按真实语速校准（6.5s 中文 ≈ 100 字）

## 测试报告

- 固定格式：`tests/schema/report.schema.json` 约束（schema_version 版本化）
- 每份报告 = 一个环境一次运行：`artifacts/reports/<run_id>/report.json` + `report.html` + `perf.csv`
- 失败用例在 HTML 报告中并排播放「本次录屏 vs 基准录屏」+ 文本差异（bug 对照）
- 性能监控：容器内 `/proc` 轻量采样器（200ms，自身开销 <1%），覆盖 fcitx5/两个合成器/录屏器/测试应用的 CPU 与内存
- `make compare` 生成历史运行对比页（各环境/方案的干扰评估）
- **报告与全部录屏都在 `artifacts/` 下，不进 git**；基准录屏仅本地保留

## 实验验证

方案讨论与验证实验放在 `experiments/`（**不进 git**）：一个想法一个文件夹（`NNN-kebab-slug/`），按 `_template/README.md` 固定格式记录，索引在 `experiments/_INDEX.md`。已完成：

- **001 Fun-ASR-Nano 本地部署**：GPU 免 sudo 直通可行（RTF 0.07、显存 3.4G、流式首包 1s）；CPU 内存最优 llama.cpp/GGUF（1.4G、RTF 0.16，暂仅 zh/en/ja）；31 语种 MLT 需 torch（int8 提速 3 倍）。建议 ASR 引擎做 gguf/torch-cpu/torch-gpu 三 provider。

## 当前进度

- ✅ M0-M5：镜像体系、编译链（addon + Flutter + GTK4/Qt6 测试应用）、三环境无头运行 + 录屏、D-Bus 测试钩子 E2E、用例管线 + 固定格式报告 + 基准对照、性能采样 + 对比页
- ✅ 实验 001/002/003：FunASR-Nano 部署矩阵、Qwen3.5-0.8B 部署、LLM 直连 vs HTTP
- ✅ F1-F5（分支 `feat/flutter-overlay-ui`，niri 容器实测）：
  - F2 addon 核心：配置 schema（configtool 生成设置页）、按键状态机（HoldRelease/Toggle、阈值、触发键组合）、Dummy 流式引擎、SimulateKey 测试钩子
  - F3 popup surface：借 waylandim IM 连接挂 `zwp_input_popup_surface_v2`，niri 光标附近显示验证通过
  - F4 Flutter MD3 UI + 快照帧桥：toImage→TCP→wl_shm 全链路，录屏四项断言（录音期可见/内容实时变化/候选切换/idle 隐藏）连续通过
  - F5 端到端 28/28：候选数字键落点、阈值透传、TriggerMode/LLMEnabled 配置热改即时生效、流式逐字单调递增、连续三轮触发（popup 复用）、100 字长文本全文提交、录音中 Esc 取消+立即复用
- ✅ G1-G4 FunASR 双档接入（真实用户语音 E2E 13/13）：
  - 宿主原生 WS 服务（无 GPU 容器）：`scripts/funasr-serve.sh`（uv venv py3.12 + MLT 模型复用实验 001 资产，RTX 3060 原生驱动）；累积窗口流式（每 720ms 全量重识别，单窗 0.25-0.9s）；**prev_text LLM 上下文实测会"锚死"早期文本，弃用**
  - addon 三档引擎：FunASR WS（parec 采音 + 手写零依赖 WS 客户端）、FunASRLocal GGUF（wav 落盘 + llama-funasr-cli 子进程非阻塞）、Dummy；configtool 枚举热切换
  - f6-test.sh 真实音频 E2E：中文流式（8 条真实 partial）+ 英语（MLT 多语种）+ GGUF 非流式 + Dummy 回归，识别文本与 `tests/expected-transcripts.json` 精确匹配
- ✅ 视觉验证改用 vision subagent（能真实感知录屏帧，替代像素取证）：确认 MD3 风格渲染正确、自适应尺寸观感合适、发现并关闭 niri hotkey-overlay 干扰
- ⬜ 后续：LLM 双后端（OpenAI 兼容 API / 本地 Qwen 直连）替换 Dummy 润色、真实音频进 case-driver 管线（audio 字段）与报告 asr_raw、kde/gnome 环境补测

## FunASR 使用（两种运行形态）

**产品形态 = 宿主原生**：模型服务跑在用户机器上（GPU 原生驱动无容器），
在 configtool「模型部署」组配置：
- `FunASRAutoStart` 开 + `FunASRServerCmd` 指向 funasr-serve.sh → addon
  连接失败时自动拉起（按 `FunASRDevice`/`FunASRQuant` 传参，模型加载
  ~15-60s 期间音频自动缓存不丢开头）
- 引擎选 `FunASR`（流式 31 语种）/ `FunASRLocal`（GGUF 本地档 zh/en/ja）

```bash
scripts/funasr-serve.sh start   # 手动起（AutoStart 关时）；FUNASR_DEVICE/QUANT/PORT 可覆盖
```

**测试形态 = 容器自含**：模型服务跑在 podman 容器（GPU 直通复用实验 001
免 sudo 模式），测试结束即销毁、宿主不留常驻进程：

```bash
scripts/funasr-container.sh start-gpu|start-cpu [quant]|status|stop
scripts/run-f6.sh               # 真实音频 E2E（funasr-gpu 容器 → niri 容器）
scripts/run-f7.sh               # 部署矩阵×configtool 深测（GPU/CPU 双容器）
```

### 部署档实测（f7，6.5s 中文样本，宿主直连冒烟）

| 档 | 首包 | 最终 | 会话(press→候选) | 资源 | 说明 |
|---|---|---|---|---|---|
| GPU（RTX 3060 Laptop, cuda:0） | **0.72s** | 4.48s | 10.2s | VRAM 3962MiB | 默认档 |
| CPU int8 量化（FUNASR_QUANT=int8） | 0.78-1.39s | 6.2-6.6s | 13.7s | RSS ~6.5-7GB | 31 语种无 GPU 兜底；量化提速（实验 001：fp32→int8 RTF 0.43→0.185），dynamic 量化不省权重内存 |
| GGUF 本地（llama-funasr-cli） | —（非流式） | ~1.3s | ~11s | RSS ~1.5GB | zh/en/ja 非流式 |
| sherpa-onnx paraformer int8（实验 004） | **0.07s** | — | — | **RSS 412MB** | **CPU 低内存流式**（zh/en，增量流式）；第四引擎档候选，见 experiments/004 |

### configtool 配置链路（f7 S1/S2）

- addon conf 需 `Configurable=True`（缺了 GetConfig/SetConfig 报 "not configurable"，configtool 不给入口）
- 保存链路 = D-Bus `SetConfig("fcitx://config/addon/voiceinput", <{...}>)` → 引擎 `setConfig()`（**基类默认 no-op，必须 override**：load + safeSaveAsIni + 应用）——本仓库曾在此缺失，GUI 能显示但保存无效
- gdbus 传 variant 需 GVariant 文本包裹：`"<{'Key': <'value'>}>"`
- GUI 冒烟：niri 容器装 fcitx5-configtool，`NIRI_SOCKET=<socket> niri msg windows` 断言窗口出现 + vision 复核渲染

## Flutter UI 里程碑细节（F1-F5）

- **尺寸自适应**（vision 复核后调整）：宽度 `TextPainter` 实测 clamp(280,420)——录音态固定 280、候选态按最长候选加宽；高度按状态（录音 104/结果按行数/候选按条数）；流式 partial 尾部优先（截头加省略号，最新内容始终可见）；快照尺寸取 boundary 实际值，addon 侧 resize 自动重建 shm 池
- **帧桥**：`RepaintBoundary.toImage` 快照 → 行式 JSON 头 + RGBA 二进制 → addon `pushFrame`（尺寸变化自动重建 shm 池）。TCP 初版够用（≤420×200×4 ≈ 336KB/帧），unix socket + memfd 零拷贝留作优化
- **窗口宿主**：flutter 进程由 addon 按需拉起（IC 激活预热，冷启动 ~3s），GTK 窗口开在 weston headless（`VOICEINPUT_UI_DISPLAY`）——cage 是单客户端 kiosk 不能用；weston headless 对普通应用客户端工作正常（此前"不能用"的结论仅限嵌套合成器场景）
- **配置热改**：写 `conf/voiceinput.config` + D-Bus `org.fcitx.Fcitx.Controller1.ReloadAddonConfig voiceinput`（接口名**不带 5**）→ `reloadConfig` 即时生效
- **测试触发**：`org.fcitx.VoiceInput.Test`（State/Candidates/SimulateKey/Trigger），确定性驱动状态机；跑 f4/f5 前屏蔽 `/usr/share/dbus-1/services/org.fcitx.Fcitx5.service`（portal/GTK 会 D-Bus 激活第二个 fcitx5 抢名）
- **验证脚本**：`scripts/env/f3-test.sh`（popup 位置）、`f4-test.sh`（UI 视觉，时间线对齐全视频扫描断言，与实际帧率无关）、`f5-test.sh`（端到端 5 场景）、`f6-test.sh`（真实音频 23 项）

## 候选交互（键盘 + 鼠标，fix/overlay-ux-input）

- **键盘**：数字 1-9 选对应候选、Enter 选第一个、Esc 取消（录音中 Esc 取消整轮）
- **鼠标**：hover 高亮 + 点击选择。实测 niri 会把 pointer enter 事件发给 IM popup 表面（同 fcitx5 classicui 机制，坐标即面板局部）——命中直走局部坐标；`text_input_rectangle`（实测送达，窗口局部）+ 放置规则复刻作兜底映射（合成器不给 enter 时）
- **virtpoint 工具**（`tools/virtpoint`）：wlr-virtual-pointer-v1 最小客户端，测试注入真实指针流（move/click）；f6 用它自动验证 hover 高亮与点击选词
- **testapp valign 修复**：GtkEntry 默认在高窗口里垂直居中，光标矩形落窗口中部导致 popup"出现得很靠下"——顶部对齐后 popup 紧贴输入框（vision 复核：标准候选栏定位，自然）
- **classicui 冲突**：注入的虚拟指针流会触发 stock classicui wl_pointer 回调空指针崩溃（真实桌面收不到这些事件无恙）——测试环境 `fcitx5 --disable=classicui`（我们的 UI 全自绘不依赖它）

### 已知限制（如实记录）

- niri 不 clamp popup 在光标上方时的顶部越界（光标贴屏幕顶会裁掉上部）；popup 定位在焦点切换后不更新（niri#4063 类）
- niri 对 IM popup 的 map/重绘由输出 damage 驱动：静止应用周期可长达 ~3.4s（map、hide 清除都滞后）；真实打字场景应用持续 damage，不受影响——testapp 用标题变化模拟
- 满栈负载下事件循环定时器节奏劣化 ~2.5x（120ms 配置实测 ~300ms/字，Dummy 流式变慢但不影响功能）

## 目录结构

```
├── Makefile
├── containers/          # 镜像定义（base/build/niri/kde/gnome/funasr + 镜像内脚本）
├── scripts/             # 宿主机侧 pipeline（build/test/report/compare + env/ record/ perf/）
├── addon/               # fcitx5 C++ 插件
├── flutter/             # Flutter UI
├── apps/                # testapp-gtk / testapp-qt 文本框测试程序
├── tests/               # 用例 yaml + 测试音频 + mock 服务 + 报告 schema
└── artifacts/           # 全部生成物（gitignore）
```
