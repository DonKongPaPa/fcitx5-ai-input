# QA 集：常见问题与处置

按现象查找。诊断基线是 fcitx5 日志（journal）：

```bash
journalctl --user --since "-10m" | grep -aE "AiInput:|VoicePopup:"
```

三条定位路径的日志特征（先确认走的哪条，再对号入座）：

| 日志特征行 | 路径 | 定位质量 |
| --- | --- | --- |
| `popup surface attached to waylandim IM` | text-input（合成器定位） | 精确 |
| `X OR 卡片窗 0x… @ x,y（rect=… root=…）` | Xwayland X 卡片 | 精确 |
| `IC 无 waylandim IM proxy（DBus 前端？）→ overlay 层卡片兜底` | D-Bus 模块 + layer 兜底 | 窗口局部坐标，多列/多屏下偏移 |

---

## Q1 Wayland 应用（ghostty / gnome-text-editor 等）卡片不贴光标，偏向窗口内容左上方

**诊断**：日志出现 `IC 无 waylandim IM proxy → overlay 层卡片兜底` + `overlay 贴光标锚定（矩形 x,y → 卡片左上 x,y）`。

**原因**：会话全局设置了 `GTK_IM_MODULE=fcitx`，应用被强制走 D-Bus 模块路径；该路径应用上报的是**窗口局部坐标**（Wayland 不暴露窗口自身位置），窗口不在屏幕原点时卡片整体偏移，偏移量=窗口原点。

**处置**：`~/.config/environment.d/`（或 `/etc/environment` 等）删除 `GTK_IM_MODULE` / `QT_IM_MODULE`，只留 `XMODIFIERS=@im=fcitx`，**重新登录**。个别应用急用可 `env -u GTK_IM_MODULE -u QT_IM_MODULE <应用>` 临时验证（单实例应用需先退旧进程）。

## Q2 gnome-text-editor 长文档里卡片飘到屏幕右下远处

**诊断**：日志出现 `X OR 卡片模式（矩形溢出判定，rect=超大值）`，rect 值超过显示器逻辑尺寸（如 3340 超过 2752 宽的逻辑屏）。

**原因**：GtkTextView 滚动时上报的是**全文档高度坐标**（虚报），被「矩形超出全部输出逻辑范围=X 物理坐标」判据误判成 Xwayland 应用，卡片按文档坐标在 X 屏落位。

**处置**：先按 Q1 去掉 IM_MODULE（走 text-input 后不再消费该矩形，问题消失）。仍在 D-Bus 路径上的应用属已知限制，避免长文档中触发。

## Q3 XWayland 应用（WPS 等）卡片跑到应用窗外的桌面区域

**诊断**：`X OR 卡片窗 … @ x,y（rect=… 父窗=… root=…）` 的 `@` 落点与 rect 差距大。

**原因**：0.4.0 前版本的父窗钳制框按「窗口在 X root (0,0)」假设计算；satellite 0.8.x 会把顶层 X 窗摆在合成器布局位置（非原点），钳制框整体错位把卡片推出窗外。0.4.0 已修复（矩形原样 + 只钳 X 屏）。

**处置**：升级 ≥0.4.0。若仍异常，记录 journal 中 `rect=` / `@` / `root=` 三个数值上报 issue。

## Q4 卡片完全不出现

**诊断**：触发后日志无任何 `卡片窗` / `layer surface created` 行；先确认模块加载（`journalctl --user -b | grep "AiInput module loaded"`）与触发键到达（`[ui] pressing` 行）。

**原因**：①模块未加载（安装后未重启 fcitx5 / 发行版包缺依赖）②触发键被其他软件占用 ③无聚焦输入框。

**处置**：①重启 fcitx5（`pkill fcitx5` 后 D-Bus `StartServiceByName org.fcitx.Fcitx5`，或直接注销重登）②configtool 换触发键 ③先点进任意输入框。

## Q5 高分屏（fractional scale）卡片模糊或尺寸不对

**诊断**：日志 `fractional scale → N`；卡片内容等比缩小/放大即命中。

**原因**：历史上 layer 表面 scale 推导错误（跨屏污染记忆值）导致缓冲比例错；0.3.x 起按 zxdg-output 精确推导并绑全部输出跟踪。

**处置**：升级 ≥0.3.0；仍异常时记录 `fractional scale →` 日志值与实际显示器 scale 上报。

## Q6 触发键（默认右 Ctrl）没反应

**诊断**：journal 无 `[ui] pressing` 行。

**原因**：①改过 TriggerKeys 配置未重启（fcitx5 KeyList 热重载上游 bug）②按键被其他工具（键盘宏/游戏软件）拦截 ③长按未过阈值（HoldRelease 模式默认 300ms）。

**处置**：①改触发键后重启 fcitx5 ②排查占用 ③configtool 调 `TriggerThresholdMs` 或切 Toggle 模式。

## Q7 会话结束后卡片残留 / 卡片出现两次

**诊断**：连续两条 `X OR 卡片窗` 或 idle 后仍有卡片。

**原因**：0.3.0.39 时代的 X 窗翻转死锁链（卡片出屏→独立顶层窗→抢焦点）已修；残留多为窗口未随会话销毁的旧版本行为。

**处置**：升级 ≥0.4.0；复现时保留 journal 全量（含 `X 错误` 行）上报。

## Q8 录音无响应/一直「识别中」

**诊断**：`[ui] recording-start` 后长时间无 `partial`，或 `[wd] 看门狗布防` 后被强制回收。

**原因**：①Sherpa 模型未下载 ②GPU/内存被占满 ③应用持续失焦（看门狗/失焦自动结束按设计工作）。

**处置**：①跑 `fetch-sherpa-models.sh`（见 README）②关闭占满显存的程序（或切 FunASR 服务档）③保持目标输入框聚焦。

## Q9 KDE（kwin）下卡片总在屏幕底部、不跟随

**诊断**：`popup surface attached` 从不出现，仅 layer 兜底。

**原因**：kwin 不实现 input-method-v2（仅 v1），合成器定位路径不可达——上游能力缺失，非缺陷。

**处置**：属已知限制（底部居中兜底为设计行为）；关注 kwin 上游 zwp_input_method_v2 支持。

## Q10 如何确认某个应用走哪条路径

在目标应用输入框触发一次，对照顶部三条日志特征行；Xwayland 应用还可查 X 侧：

```bash
DISPLAY=:0 xprop -root _NET_ACTIVE_WINDOW   # 非 0x0 ⟺ 当前聚焦的是 X 应用
```

环境变量自查：`systemctl --user show-environment | grep IM_MODULE`——出现 `GTK_IM_MODULE/QT_IM_MODULE` 即存在 Q1 风险。
