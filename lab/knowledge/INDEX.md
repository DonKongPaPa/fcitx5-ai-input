# 原子避坑知识资产 INDEX

共 72 条（wayland 14 · x11 12 · fcitx-api 12 · embedder 5 · app-behavior 4 · container-test 17 · build-deploy 8）。每条一文件：症状/根因/约束规则/来源/验证。
规则：重构动到的模块先过该类目清单；能固化为断言的进对应容器用例。
再生成：`python3 lab/knowledge/gen.py`（条目定义在脚本 ITEMS 内，加条目只改数据）。

## wayland
- [wl-listener-data-slot](wl-listener-data-slot.md) libwayland listener data 与 proxy user_data 同槽
- [wl-input-popup-single-slot](wl-input-popup-single-slot.md) smithay input popup 单槽 last-create-wins
- [wl-per-surface-state-rebuild](wl-per-surface-state-rebuild.md) per-surface 状态必须随 surface 重建全量重放
- [wl-state-atomic-with-buffer](wl-state-atomic-with-buffer.md) 表面状态变更须与承载 buffer 原子成对
- [wl-empty-input-region](wl-empty-input-region.md) 隐藏态必须显式清空输入区
- [wl-surface-listener-v5-slots](wl-surface-listener-v5-slots.md) wl_surface listener v5 槽位不能留 NULL
- [wl-pointer-set-cursor](wl-pointer-set-cursor.md) pointer enter 后必须 set_cursor
- [wl-fractional-last-known](wl-fractional-last-known.md) 新 surface fractional 未到时用上次值兜底
- [wl-scale-from-zxdg-output](wl-scale-from-zxdg-output.md) 精确 scale 用 zxdg-output 推导
- [wl-preedit-needs-updatepreedit](wl-preedit-needs-updatepreedit.md) client preedit 必须经 updatePreedit() 送达应用
- [wl-rect-latency-unbounded](wl-rect-latency-unbounded.md) 光标矩形延迟无上界，禁用固定截止窗
- [wl-chromium-rect-only-on-change](wl-chromium-rect-only-on-change.md) chromium 系只在文本/光标变化时报矩形
- [wl-niri-popup-no-clamp](wl-niri-popup-no-clamp.md) niri 不替 input popup 滑位/钳制
- [wl-mutter-rect-storm](wl-mutter-rect-storm.md) mutter 每帧重发同值 text_input_rectangle（矩形风暴）

## x11 / satellite
- [x-cw-valueorder](x-cw-valueorder.md) xcb CreateWindow 值列表必须按 CW 位序
- [x-error-events-not-silent](x-error-events-not-silent.md) X 错误事件不能静默吞
- [x-gc-per-window](x-gc-per-window.md) GC 必须随窗口销毁重建
- [x-argb32-visual](x-argb32-visual.md) 32 位 ARGB visual + colormap 才有透明
- [x-satellite-root-origin](x-satellite-root-origin.md) satellite 顶层 X 窗 root 摆位随版本变：0.3 恒 (0,0)，0.8.2 按合成器布局定位
- [x-satellite-parent-bounds](x-satellite-parent-bounds.md) OR 卡片必须钳入聚焦 X 顶层窗范围
- [x-gtkscale-rect-root-coords](x-gtkscale-rect-root-coords.md) fcitx5-gtk 矩形=X root 坐标（含窗口原点）；钳制框必须用窗口 root 范围
- [x-satellite-or-no-pointer](x-satellite-or-no-pointer.md) satellite 0.8.2 不向 override-redirect 窗投递指针事件
- [x-satellite-screen-model](x-satellite-screen-model.md) satellite X 屏=逻辑原点+物理范围
- [x-active-window-classifier](x-active-window-classifier.md) _NET_ACTIVE_WINDOW 存在⟺聚焦应用是 X 应用
- [x-gtk-scrolled-doc-coords](x-gtk-scrolled-doc-coords.md) GTK 滚动文档坐标虚报
- [x-xshm-works](x-xshm-works.md) MIT-SHM 在 satellite 下可用

## fcitx5 API
- [fc-kwin-im-v1-only-pool-gate](fc-kwin-im-v1-only-pool-gate.md) 嵌套 kwin 只有 input-method v1——shm 池门控被卡死
- [fc-xcb-interface-target](fc-xcb-interface-target.md) Fcitx5::Module::XCB 是 INTERFACE 目标
- [fc-setconfig-string-values](fc-setconfig-string-values.md) D-Bus SetConfig 的值必须是字符串
- [fc-config-section-append](fc-config-section-append.md) 配置文件追加键不能落进节内
- [fc-setconfig-override](fc-setconfig-override.md) addon 必须实现 setConfig 覆写
- [fc-addon-reload-remote-r](fc-addon-reload-remote-r.md) 容器里 fcitx5-remote -r 不触发 addon reloadConfig
- [fc-input-popup-api](fc-input-popup-api.md) getInputMethodV2 仅对 wayland_v2 IC 非空
- [fc-classicui-dispatch](fc-classicui-dispatch.md) classicui 对 dbus+wayland IC 强制 X11 UI（上游自认位置错）
- [fc-timer-usec](fc-timer-usec.md) addTimeEvent 用绝对 µs + setOneShot
- [fc-uieventloop-include](fc-uieventloop-include.md) EventLoop 完整定义在 event.h
- [fc-dbus-im-protocol-paths](fc-dbus-im-protocol-paths.md) dbus 前端 IM 协议路径与接口
- [fc-uim-single-active-dispatch](fc-uim-single-active-dispatch.md) InputPanel 只派发给唯一活跃 UI（ui_），非全体

## flutter embedder
- [em-pointer-physical-space](em-pointer-physical-space.md) FlutterPointerEvent 坐标必须是物理像素
- [em-jit-only](em-jit-only.md) 官方 embedder 只有 JIT 变体
- [em-engine-hash-sdk-coupling](em-engine-hash-sdk-coupling.md) 引擎 .so 必须与构建 kernel 的 SDK 同 hash
- [em-window-natural-intrinsic](em-window-natural-intrinsic.md) 窗口尺寸=内在尺寸+持久帧回调（勿回测量路）
- [em-metrics-dpr-cache](em-metrics-dpr-cache.md) updateMetrics 时缓存 dpr 供 pointer 换算

## 应用行为
- [app-dbus-rect-window-local](app-dbus-rect-window-local.md) DBus 前端矩形=窗口局部（原点结构性缺失）
- [app-gtk-commit-no-rect-rereport](app-gtk-commit-no-rect-rereport.md) 程序性 commit 不触发矩形重报
- [app-textinput-compositor-positioned](app-textinput-compositor-positioned.md) wayland 原生应用走 text-input 才有合成器级精确定位
- [app-qt-dbus-needs-machineid](app-qt-dbus-needs-machineid.md) Qt 的 QDBusConnection 需要 /etc/machine-id

## 容器与测试
- [ct-satellite-nested-container](ct-satellite-nested-container.md) xwayland-satellite 可挂嵌套合成器链（容器 X 仿真）
- [ct-grep-q-sigpipe](ct-grep-q-sigpipe.md) printf|grep -q 早退撞 SIGPIPE——pipefail 下大窗口恒假败
- [ct-bash-or-and-precedence](ct-bash-or-and-precedence.md) bash {A&&B||C&&D} 左结合拆散双档断言
- [ct-env-capability-matrix](ct-env-capability-matrix.md) 合成器能力矩阵：popup 与指针注入是两个独立维度
- [ct-case-config-leak](ct-case-config-leak.md) 用例改配置必须还原到产品默认（不是任意安全值）
- [proto-json-dumps-space](proto-json-dumps-space.md) python json.dumps 默认冒号后带空格，紧凑解析器全盲
- [glib288-variant-traps](glib288-variant-traps.md) glib 2.88 GVariant 三个坑（ic-sim 实证）
- [ct-scale-wildcard-winit](ct-scale-wildcard-winit.md) 嵌套 niri 输出名不吃 output "*" 通配
- [ct-pkill-hits-container](ct-pkill-hits-container.md) 宿主 pkill 杀容器内同名进程
- [ct-skip-false-green](ct-skip-false-green.md) 守卫恒假→静默跳过→假绿
- [ct-wfrecorder-kill9](ct-wfrecorder-kill9.md) 1080p 下 wf-recorder 无视 SIGINT/SIGTERM
- [ct-virtpoint-extent-normalization](ct-virtpoint-extent-normalization.md) virtpoint 坐标经 extent 归一化（分辨率无关）
- [ct-injectkey-vs-simulatekey](ct-injectkey-vs-simulatekey.md) SimulateKey 直喂状态机；InjectKey 走真实事件管线
- [ct-session-residue-swallows-trigger](ct-session-residue-swallows-trigger.md) 候选/录音残留吞下一用例触发键
- [ct-headless-nested-screencopy](ct-headless-nested-screencopy.md) 嵌套 niri 的 screencopy 不出帧，录屏对宿主合成器
- [ct-pil-in-container-only](ct-pil-in-container-only.md) niri 镜像内有 pillow；宿主无
- [ct-stdin-consumed-by-chain](ct-stdin-consumed-by-chain.md) 交互容器 stdin 会被调用链吞掉

## 构建与部署
- [bd-headless-popup-guard](bd-headless-popup-guard.md) headless 环境 popup 分支必须判空 im_
- [bd-local-lib-not-searched](bd-local-lib-not-searched.md) ~/.local/lib 不入 addon 搜索路径
- [bd-deploy-verify-artifacts](bd-deploy-verify-artifacts.md) 上机前验证产物：readelf/ldd -r/字符串
- [bd-build-in-tmp](bd-build-in-tmp.md) 容器内 /tmp 干净构建防时间戳跳过
- [bd-cage-headless-fixed-720p](bd-cage-headless-fixed-720p.md) cage headless 输出 1280×720 硬编码
- [bd-setcap-strip](bd-setcap-strip.md) 合成器二进制的 cap_sys_nice 需移除
- [bd-journal-user-restarts](bd-journal-user-restarts.md) 用户会自行重启 fcitx5（终端启动无 journal）
- [bd-log-buffering-tail-caveat](bd-log-buffering-tail-caveat.md) fcitx5 stderr 重定向到文件是块缓冲
