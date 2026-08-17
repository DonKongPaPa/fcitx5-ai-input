# fcitx5-voice-input

基于 fcitx5 的语音输入法：ASR 识别语音，LLM 优化输出结果（标点、纠错、分段），文本提交到光标处。

## 总体架构

```
[麦克风] → [fcitx5 C++ addon] ←D-Bus→ [Flutter UI：悬浮窗渲染 + 设置页]
                │
                ├── ASR 引擎抽象：FunASR 本地服务（WebSocket 流式），后续多引擎设置页可切换
                ├── LLM 优化抽象：① OpenAI 兼容 API ② 本地小模型直连（llama.cpp 加载 Qwen，不走 HTTP）
                └── 定位：addon 从 InputContext 取光标位置计算后下发，Flutter 只负责渲染
```

- addon 目录：fcitx5 插件（引擎侧：录音、ASR、LLM、提交文本、悬浮窗定位）
- flutter 目录：UI 渲染 + 设置页

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
- weston headless 是 no-op 渲染器不驱动帧时钟，不能当无头宿主用

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

## 测试报告

- 固定格式：`tests/schema/report.schema.json` 约束（schema_version 版本化）
- 每份报告 = 一个环境一次运行：`artifacts/reports/<run_id>/report.json` + `report.html` + `perf.csv`
- 失败用例在 HTML 报告中并排播放「本次录屏 vs 基准录屏」+ 文本差异（bug 对照）
- 性能监控：容器内 `/proc` 轻量采样器（200ms，自身开销 <1%），覆盖 fcitx5/两个合成器/录屏器/测试应用的 CPU 与内存
- `make compare` 生成历史运行对比页（各环境/方案的干扰评估）
- **报告与全部录屏都在 `artifacts/` 下，不进 git**；基准录屏仅本地保留

## 当前进度

- ✅ M0-M5：镜像体系、编译链（addon + GTK4/Qt6 测试应用）、三环境无头运行 + 录屏、D-Bus 测试钩子 E2E、用例管线 + 固定格式报告 + 基准对照、性能采样 + 对比页
- ⬜ 后续：FunASR WebSocket 引擎接入（虚拟麦克风 → 流式识别）、LLM 双后端（OpenAI 兼容 API / 本地 Qwen 直连）、Flutter UI（悬浮窗渲染 + 设置页）、真实音频用例替换 Trigger 直通

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
