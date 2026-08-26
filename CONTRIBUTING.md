# 贡献指南

本仓库的开发与测试全部在 **podman 容器** 内进行——不依赖贡献者的桌面环境，也不拿真实桌面当试验场。首次准备约需 40GB 磁盘与 20-40 分钟（镜像构建）。

## 快速开始

```bash
make images              # 构建全部镜像（base → host → build/niri/kde/gnome）
make build               # 编译 addon + Flutter 资产 + 测试应用 → artifacts/dist/（Flutter 全链在 aiinput-build 镜像 SDK 内产出，宿主无需装 flutter）
make test ENV=niri       # 跑全套件（S 组 smoke + C 组 corner）→ artifacts/reports/<run_id>/report.html
SUITE=smoke make test ENV=niri   # 只跑部署后运行检查（5 例，~1 分钟）
SUITE=corner make test ENV=niri  # 只跑 corner case 集中轮（15 例）
make test-all            # niri + kde + gnome 三环境
make shell ENV=niri      # 交互式进入环境容器调试
```

可选模型（启用 c13-c15 真实引擎用例；无模型时这些用例记"跳过"）：

```bash
bash scripts/fetch-sherpa-runtime.sh     # sherpa-onnx 运行时（版本锁定）
bash scripts/fetch-sherpa-models.sh      # 流式模型 → ~/.local/share/fcitx5-aiinput/models/
```

前置：Linux + rootless podman；`podman images` 应无残留同名镜像冲突。语音样本见下文「测试资产」。

## 测试体系架构

```
make test ENV=niri
  └─ scripts/run-test.sh                 # 宿主侧编排
       └─ podman run aiinput-niri     # 挂载 /scripts /opt/dist /tests /samples [/models]
            └─ start-niri.sh MODE=case   # 无头桌面拉起（sway 托管 niri，1080p + 录屏器）
                 └─ case-driver.sh       # 用例执行（本套件核心）
                      ├─ record <id> <pass|fail> <msg>   # 每例一行 → case-results.jsonl
                      ├─ journal 断言（grep addon 日志）
                      └─ 录屏 rec-<case>.mp4 + grim 截图
       └─ scripts/report.py              # 汇总 report.json/html（失败用例并排播放本次 vs 基准录屏）
```

- **一个桌面 = 一个容器**：niri（sway 托管，1920×1080 headless——cage 的 headless 输出 1280×720 硬编码不可调）/ kde（kwin_wayland + sway 托管）/ gnome（mutter 嵌套 + sway 托管）；镜像层级 base → host → 各桌面，`aiinput-build` 为编译镜像，`aiinput-funasr` 为 FunASR 服务镜像
- **scale 矩阵**：`make test` 默认两轮（scale 1.0 正常 + 2.0 放大，各自独立报告）；`NIRI_TEST_SCALE=x` 单档、`SCALE_MATRIX="1.0 1.5 2.0"` 自定义。用例内坐标全部经 virtpoint extent 归一化（分辨率无关），像素断言用比例值
- **确定性触发**：测试经 D-Bus 测试钩子（`org.fcitx.AiInput.Test` 的 `SimulateKey` / `InjectKey` / `State` / `Candidates` / `Trigger`）直达 addon 状态机，不依赖真实 ASR；真实音频用例经虚拟麦（`play_to_mic`）喂 wav
- `SimulateKey` 只喂状态机；`InjectKey` 走真实事件管线（验证拦截/透传语义）；裸字母键在 keyboard-us 下不会到达应用文本框（只有组合文本会）——需要应用侧文本变化时用触发键/候选上屏或拼音组合
- **两组结构（2026-08-26 重构，37→20）**：S 组 s1-s5 = 部署后运行检查（模块/引擎/版本/基本会话 E2E/HealthCheck，`SUITE=smoke` 单独跑）；C 组 c1-c15 = corner case 集中轮（键盘语义、IC 生命周期、看门狗、失焦自愈、定位矩阵、引擎档）。完整 20 例仅在 niri 达成，kde/gnome 镜像缺 chromium/virtpoint 的用例自动记"pass（跳过）"
- 性能采样：容器内 `/proc` 轻量采样器（自身开销 <1%）随套件全程运行 → `perf.csv`
- `make baseline` 把通过用例的录屏存为基准；之后失败用例的 HTML 报告会并排播放「本次 vs 基准」；`make compare` 生成历史运行对比页

## 如何新增用例

在 `scripts/env/case-driver.sh` 对应组里加一段（现有 s/c 系均为此式），编号递增、一个场景一个用例：

```bash
# c16 <场景名>：<一句话意图>
c16_mark=$(wc -l < "$FCITX_LOG")          # 记日志水位
call SimulateKey "Control+Control_R" true # 触发（D-Bus helper）
play_to_mic "samples/xxx.wav"             # 需要真实音频时
sleep 2
c16_win="$(tail -n +$((c16_mark+1)) "$FCITX_LOG")"
if printf '%s' "$c16_win" | grep -aq '<期望日志>'; then
    record c16-<slug> pass "描述"
else
    record c16-<slug> fail "诊断信息"
fi
```

约定：

- 断言优先用 addon journal 日志（`VoicePopup:` / `[ui]` / `Sherpa:` 前缀）；位置/渲染类结论用录屏或 `grim` 截图，需视觉判断时人工复核截图
- 依赖 chromium / 录屏 / 模型的用例必须写跳过分支（`record <id> pass "（跳过：原因）"`），保证 kde/gnome/无模型环境总用例数一致
- 每轮录音会话结束必须 `back_to_idle` 收尾（候选/录音残留会吞下一用例的触发键——三次踩坑后固化为公共函数）
- fcitx 配置 D-Bus SetConfig 的值必须字符串（`<'10'>`；int32 被静默丢弃落默认值）
- case-driver 头部「用例地图」同步更新

## 测试资产

- **语音样本**：`语音测试集/`（gitignored，真实人声 6.3-6.5s FLAC）→ 派生 16k 单声道 wav 放 `artifacts/voice-samples/`（gitignored），容器内挂 `/samples`
- **报告与录屏**：全部在 `artifacts/`（gitignored）
- **实验记录**：方案探索放 `experiments/NNN-slug/`（gitignored，`_template/` 有固定格式，索引在 `_INDEX.md`）——结论沉淀进代码注释或文档后，实验目录只是过程档案

## 容器无头桌面踩坑（前人种树）

- kwin/sway 自带 `cap_sys_nice` filecap → rootless 容器 exec EPERM → 镜像内 `setcap -r`（Containerfile.kde 已做）
- 双 GPU 机器只直通第一个渲染节点：NVIDIA 节点参与会跨设备 dmabuf 拷贝失败
- wf-recorder 需两个补丁（`containers/patches/`）：ffmpeg 9 API 适配 + dmabuf 绑定版本协商
- weston headless 是 no-op 渲染器不驱动帧时钟，不能当无头宿主
- 测试环境**不设** `GTK_IM_MODULE`：应用必须走原生 text-input-v3（frontend=wayland_v2）才有 IM 激活与光标矩形
- 容器内跑 fcitx5 前屏蔽 `/usr/share/dbus-1/services/org.fcitx.Fcitx5.service`（否则 portal/GTK 会 D-Bus 激活第二个 fcitx5 抢名）；孤儿容器会阻塞同环境重跑，`podman rm -fa` 后再跑
- pipewire/pipewire-pulse 启动有 socket 目录竞争，`start_audio` 已带自愈重试；`pactl load-module` 的错误打到 stdout，取 module id 后必须校验为纯数字
- 注入的虚拟指针流会触发 classicui wl_pointer 回调空指针崩溃（真实桌面无恙）——测试容器 `fcitx5 --disable=classicui`

## 验证纪律

- **一切复现进容器**：用户桌面不是试验场；宿主机只做最终部署验收
- **部署验证查 `/proc/<pid>/maps`**：确认加载的是新装路径的二进制，别信"装了就该生效"（`~/.local` 残留会遮蔽包安装，系统包路径必须优先）
- **journal 自己查**：排查靠 `journalctl --user` 里 addon 的结构化日志，不请用户跑命令取证据
- shell 陷阱：`grep -c` 零匹配退出码 1 会断 `&&` 链（套件曾因此静默跑旧二进制）；脚本改完后 `bash -n` 过一遍语法
- 纯修饰键触发键（右 Ctrl）的匹配依赖真实键盘事件的 keycode——`SimulateKey` 合成的干净键不暴露此差异，触发键语义改动须在容器注入真实键形（r8/r12）或宿主机实测

## 代码风格

- C++：仓库根 `.clang-format`（fcitx5 上游同款）——提交前 `clang-format -i`，现有代码已零漂移，别引入风格 diff
- **注释写约束，不写调试史**。注释应当回答"代码看不出来的为什么"：协议/合成器行为、勿复活的坑、API 陷阱。反例（不要这样）：

  ```cpp
  // r27 实测 0ms；空格上屏+回删方案 r25 两跑同败，宿主机实测冻结 31s（实验 005）
  ```

  正例：

  ```cpp
  // 上屏+回删会扰动状态机编舞，勿复活；chromium 只在文本变化时报矩形
  ```

  用例编号、实验编号、实测数据属于 git 提交信息与实验记录，不属于代码
- Dart：单文件 `flutter/lib/main.dart`，协议注释在文件头；C++ 侧宿主是 `flutter_engine.{h,cpp}`
- 命名与日志风格跟随现有代码（日志中文、`VoicePopup:` / `AiInput:` 前缀）

## 提交与分支

- 提交信息：`feat:` / `fix:` / `chore:` / `docs:` / `refactor:` 前缀 + 中文主题，一行说清"做了什么"；多轮调试的来龙去脉写进 body
- **一个功能分支一个里程碑**（`feat/xxx`、`fix/xxx`），完成后合回 `main`，不长期堆积旧分支
- PR 到 `main`；改动 addon/Flutter 的须附 `make gate-merge` 全绿（niri 20/20 × 双 scale）的运行报告号

## 发布

tag `vX.Y.Z` 后 GitHub Actions `Release` workflow（`workflow_dispatch` 传 version）自动构建四平台包（Arch/Debian/Fedora/tarball）+ Flutter JIT bundle 并创建 Release。发版前确认 `packaging/` 各 `build.sh` 与版本占位符就绪。

## 试验田（lab/）与快档测试

- `lab/spec/protocol.md`：消息流转规范 v1（ui/asr/refine 三通道统一 envelope）；
  `lab/spec/events/*.jsonl` 回放脚本；`lab/knowledge/` 原子避坑知识资产
  （重构动模块前先过类目清单，`python3 lab/knowledge/gen.py` 增条目）
- `UI_TRANSPORT=mock UI_REPLAY=<jsonl> flutter run -d linux`：dummy 驱动 UI
  演示（见 lab/player/README.md）
- `make ui-test`：UI 层快档容器（flutter test+golden+回放断言，复用
  aiinput-build 镜像，~40s）；golden 基线只在容器内生成/校验（SDK pin），
  更新用 `UPDATE_GOLDENS=1 ./scripts/run-ui-test.sh` 后人工审图
- `make proto-test`：协议快档容器（envelope/事件参数校验+跨通道对拍
  不变量——ui↔asr↔refine 语义一致性，hub 参考行为规约；秒级，
  aiinput-base 零依赖）——改 protocol.md/events 后必跑
- `make addon-test`：无显示状态机快档容器（ic-sim 纯 D-Bus 造 IC 驱动
  按键语义/看门狗/失焦/跨 IC/引擎流，aiinput-base，~40s）——改 addon
  会话逻辑后跑；ic-sim 用法见 apps/ic-sim/ic-sim.c 头注释
- `make surface-test SC=S4`：定位根因分析容器（单场景 ~1min：双引擎差分
  bbox + HTML 并排报告 + 标注图素材）。场景 S1-S6 见
  scripts/env/surface-driver.sh；vision 二次测量按
  lab/surface/vision-probe.md 中性模板（防暗示纪律）

### 快档 / 广档触发规则

针对性场景测试要快（秒级容器，日常迭代随手跑），合并/发版前测试要广（全套件矩阵，门禁跑）：

| 改动面 | 日常必跑（快档） | 说明 |
| --- | --- | --- |
| `flutter/lib/**` | `make ui-test` | widget/golden/回放，~40s |
| `lab/spec/**`、`backends/**`（协议/后端脚本） | `make proto-test` | 对拍器秒级（含后端实拍：驱动真实子进程产物过同一校验器），改协议或后端后必跑 |
| `addon/src/core/`、`addon/src/hub/`（会话/协议） | `make addon-test` | 无显示状态机 7 例 |
| `addon/src/surfaces/`（定位/表面） | `make addon-test` + `make surface-test SC=<场景>` | 定位问题先单场景收敛 |
| `apps/ic-sim/`、`scripts/env/*-driver.sh` | 对应档 | 驱动/工具改动随档生效 |

- **合并前门禁（广档）**：`make gate-merge` = niri 全套件双 scale（20×2），
  feat 分支合回 `main` 前必跑且全绿
- **发版前门禁（最广）**：`make gate-release` = niri + kde + gnome 三环境
- e2e（`make test`）不当日常迭代回路：会话逻辑去 addon-test、协议去
  proto-test、定位去 surface-test，收敛后再进广档
- 基础镜像变更（`containers/Containerfile.base`）波及全部下游镜像：
  重建 base 后 `make images` 重建链再跑 gate-merge（镜像级改动可能把
  静默惰性的用例腿变真实——如 +fcitx5-chinese-addons 激活 c7 抢槽腿）
