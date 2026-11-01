// card-qml/shell.qml —— Quickshell 入口：语音卡 + rime 候选面板双 layer 表面
// 传输选型（containers/qml-probe 结论）：Io 模块无读自身 stdin 的类型，走
// Socket 客户端 + SplitParser 按行收 envelope；write 不自动补 \n，写后须 flush。
// 协议（lab/spec/protocol.md v1）：只消费 channel=="ui" && dir=="out"，
// 未知 method 忽略；命令方向（ready/resize/select/hover/navigate/cancel）
// 经同一 socket 回写。
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
    id: root

    // socket 路径经环境变量交接（feed.py 默认值一致），QML 侧不硬编码绝对路径
    property string sockPath: Quickshell.env("AIINPUT_CARD_SOCK") !== ""
                                  ? Quickshell.env("AIINPUT_CARD_SOCK")
                                  : "/run/user/1000/aiinput-card.sock"
    // theme{font_path} 的热加载源（FontLoader 异步加载，失败回落系统默认）
    property string fontPath: ""
    property int sendSeq: 0
    property int recvCount: 0
    property int ignoredCount: 0
    property var caps: []
    // panel/caret 的光标矩形（跟随锚定源；声明缺失曾导致赋值静默失败
    // ——「Cannot assign to non-existent property」，margins 恒默认）
    property var lastCaret: null

    Theme {
        id: themeObj
    }

    FontLoader {
        id: themeFontLoader
        source: root.fontPath === "" ? "" : "file://" + root.fontPath
        // 与 theme{font_family} 的显式指定后到者赢（原型简化）
        onNameChanged: themeObj.fontFamily = name
    }

    // —— 语音卡（跟随光标；无 caret 时兜底左下）——
    // idle 即整窗退场：原型期常驻的「待机胶囊」占一层 layer surface 且
    // 挤占注意力（宿主实测反馈），真实版语义 = 无会话无表面
    PanelWindow {
        id: cardWindow
        visible: card.mode !== "idle"
        color: "transparent"
        anchors {
            left: true
            top: true
        }
        margins {
            left: root.cardAnchorLeft
            top: root.cardAnchorTop
        }
        exclusionMode: ExclusionMode.Ignore
        implicitWidth: card.implicitWidth
        implicitHeight: card.implicitHeight

        // namespace 陷阱：windowConnected 后不可改（官方文档），创建时定死
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.namespace: "aiinput-card"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        Card {
            id: card
            anchors.centerIn: parent
            theme: themeObj
            onSelectRequested: index => root.sendEnvelope("select",
                                                          { index: index })
            onHoverRequested: row => root.sendEnvelope("hover", { row: row })
            onCancelRequested: () => root.sendEnvelope("cancel", {})
        }

        // UI 内在尺寸上报（协议 §4.2 resize{w,h}）：布局稳定后去抖再报
        Timer {
            id: cardResizeTimer
            interval: 200
            onTriggered: {
                if (cardWindow.width > 0 && cardWindow.height > 0) {
                    root.sendEnvelope("resize", {
                        w: cardWindow.width,
                        h: cardWindow.height
                    })
                }
            }
        }
        onWidthChanged: cardResizeTimer.restart()
        onHeightChanged: cardResizeTimer.restart()
        Component.onCompleted: cardResizeTimer.restart()
    }

    // —— rime 候选面板（panel/update 显示、panel/hide 隐藏、caret 重锚）——
    PanelWindow {
        id: panelWindow
        visible: panel.shown
        color: "transparent"
        anchors {
            left: true
            top: true
        }
        margins {
            left: root.panelAnchorLeft
            top: root.panelAnchorTop
        }
        exclusionMode: ExclusionMode.Ignore
        implicitWidth: panel.implicitWidth
        implicitHeight: panel.implicitHeight

        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.namespace: "aiinput-panel"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        Panel {
            id: panel
            anchors.centerIn: parent
            theme: themeObj
            onSelectRequested: index => root.sendEnvelope("select",
                                                          { index: index })
            onHoverRequested: row => root.sendEnvelope("hover", { row: row })
            onNavigateRequested: delta => root.sendEnvelope("navigate",
                                                            { delta: delta })
        }

        Timer {
            id: panelResizeTimer
            interval: 200
            onTriggered: {
                if (panelWindow.visible && panelWindow.width > 0
                        && panelWindow.height > 0) {
                    root.sendEnvelope("resize", {
                        w: panelWindow.width,
                        h: panelWindow.height
                    })
                }
            }
        }
        onWidthChanged: panelResizeTimer.restart()
        onHeightChanged: panelResizeTimer.restart()
        onVisibleChanged: panelResizeTimer.restart()
    }

    // —— 传输（feeder 须先 listen；断线重连照探针模式：connected 目标态两段置位）——
    Socket {
        id: sock
        path: root.sockPath
        connected: true
        parser: SplitParser {
            onRead: line => root.handleLine(line)
        }
        onConnectionStateChanged: {
            console.log("CARD: SOCK connected=" + connected)
            if (connected) {
                retryTimer.stop()
                root.sendEnvelope("ready", {}) // 协议 §4.2：UI 引擎就绪
            }
        }
        onError: () => retryTimer.restart()
    }
    Timer {
        id: retryTimer
        interval: 600
        // connected 是目标态：先置 false 再置 true 才会重连（探针实测）
        onTriggered: {
            sock.connected = false
            reconnectTimer.restart()
        }
    }
    Timer {
        id: reconnectTimer
        interval: 200
        onTriggered: sock.connected = true
    }

    // caret 锚定（root 内联属性绑定：块表达式直引 id.property，依赖捕获
    // 可靠；函数调用式绑定对函数内属性访问不保证重算——实测 margins 停在
    // 默认值）。rect 为窗口局部坐标按输出坐标近似用（同 DbusPosition=
    // follow 前提；浮动窗有原点偏差——best effort，QA Q11 同款）
    readonly property int cardAnchorLeft: {
        var sw = cardWindow.screen ? cardWindow.screen.width : 1920
        return root.lastCaret
                   ? Math.round(Math.max(8, Math.min(
                         root.lastCaret.x, sw - card.implicitWidth - 8)))
                   : 8
    }
    readonly property int cardAnchorTop: {
        var sh = cardWindow.screen ? cardWindow.screen.height : 1080
        if (!root.lastCaret)
            return 0
        var t = root.lastCaret.y + root.lastCaret.h + 8
        return Math.round(t + card.implicitHeight > sh - 8
                              ? Math.max(8, root.lastCaret.y
                                               - card.implicitHeight - 8)
                              : t)
    }
    readonly property int panelAnchorLeft: {
        var sw = panelWindow.screen ? panelWindow.screen.width : 1920
        return root.lastCaret
                   ? Math.round(Math.max(8, Math.min(
                         root.lastCaret.x, sw - panel.implicitWidth - 8)))
                   : 8
    }
    readonly property int panelAnchorTop: {
        var sh = panelWindow.screen ? panelWindow.screen.height : 1080
        if (!root.lastCaret)
            return 0
        var t = root.lastCaret.y + root.lastCaret.h + 8
        return Math.round(t + panel.implicitHeight > sh - 8
                              ? Math.max(8, root.lastCaret.y
                                               - panel.implicitHeight - 8)
                              : t)
    }

    function handleLine(line) {
        if (!line || !line.trim())
            return
        var env
        try {
            env = JSON.parse(line)
        } catch (e) {
            console.log("CARD: BADJSON " + line.substring(0, 80))
            return
        }
        // v1 envelope 门禁：v/channel/dir 不符一律忽略（协议 §2/§8）
        if (env.v !== 1 || env.channel !== "ui" || env.dir !== "out") {
            root.ignoredCount++
            return
        }
        var args = env.args === undefined ? {} : env.args
        switch (env.method) {
        case "hello":
            root.caps = args.caps === undefined ? [] : args.caps
            panel.caps = root.caps
            break
        case "theme":
            if (args.font_path !== undefined)
                root.fontPath = args.font_path
            if (args.font_family !== undefined && args.font_family !== "")
                themeObj.fontFamily = args.font_family
            if (args.font_size !== undefined)
                themeObj.baseFontSize = args.font_size
            if (args.scale !== undefined)
                themeObj.scale = args.scale
            if (args.anim !== undefined)
                themeObj.anim = args.anim
            break
        case "voice/recording":
            card.showRecording(args.partial === undefined ? "" : args.partial,
                               args.elapsed_ms === undefined
                                   ? 0 : args.elapsed_ms)
            break
        case "voice/result":
            card.showResult(args.final === undefined ? "" : args.final,
                            args.timeout_ms === undefined ? 0 : args.timeout_ms)
            break
        case "voice/candidates":
            card.showCandidates(args.final === undefined ? "" : args.final,
                                args.candidates === undefined
                                    ? [] : args.candidates,
                                args.hover === undefined ? -1 : args.hover,
                                args.llm_dummy === true)
            break
        case "voice/idle":
            card.showIdle()
            break
        case "panel/update":
            panel.applyUpdate(args)
            break
        case "panel/hide":
            panel.hidePanel()
            break
        case "panel/caret":
            // 跟随（M2 补齐）：光标矩形 → layer margins 重锚。rect 为
            // 窗口局部坐标按输出坐标近似用（同 DbusPosition=follow 的
            // 坐标系前提，铺满输出的窗口即精确；浮动窗有原点偏差，Wayland
            // 不暴露其它 surface 位置——best effort，QA Q11 同款）
            console.log("CARD: caret hit, rect=" + JSON.stringify(args.rect))
            root.lastCaret = args.rect // 绑定自动重算两窗口 margins
            break
        default:
            root.ignoredCount++ // 未知 method 忽略（向前兼容）
            return
        }
        root.recvCount++
        console.log("CARD: ENV seq=" + (env.seq === undefined ? -1 : env.seq)
                    + " method=" + env.method)
    }

    function sendEnvelope(method, args) {
        root.sendSeq++
        // write 不自动补 \n（官方文档），写后必须 flush
        sock.write(JSON.stringify({
            v: 1,
            channel: "ui",
            dir: "in",
            method: method,
            seq: root.sendSeq,
            args: args
        }) + "\n")
        sock.flush()
    }
}
