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

| 容器镜像 | 合成器 | 无头方式 | 录屏 |
|---|---|---|---|
| `voiceinput-niri` | niri | `WLR_BACKENDS=headless` | wf-recorder |
| `voiceinput-kde` | kwin_wayland | `--virtual` 虚拟输出 | gpu-screen-recorder / Spectacle |
| `voiceinput-gnome` | gnome-shell / mutter | `--wayland --headless` | gnome-shell 内置 Screencast |

- 基础镜像 `voiceinput-base`：Arch + 中国 pacman 镜像（TUNA/USTC）+ fcitx5 + noto-fonts-cjk + pipewire + mesa(llvmpipe)
- 编译镜像 `voiceinput-build`：base + 工具链 + Flutter SDK（flutter-io.cn 中国镜像）
- `voiceinput-funasr`：FunASR 运行时（模型走 ModelScope），真实引擎手动测试用；**管线测试一律用确定性 Mock**

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
- **报告与全部录屏都在 `artifacts/` 下，不进 git**；基准录屏仅本地保留

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
