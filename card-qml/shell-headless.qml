// card-qml/shell-headless.qml —— frame-relay 离屏渲染场景（aiinput-card-host
// 装载，无窗口）。与 shell.qml 的分工（lab/spec/frame-relay.md §2 渲染/定位
// 分离）：本文件只管「画什么」，定位全交 VoicePopup 的 input-popup surface
//（合成器贴光标）——因此无 PanelWindow、无 caret 重锚、无 resize 回报（帧
// 尺寸即内在尺寸，pushFrameRelay 直入物理像素）。协议消费逻辑与 shell.qml
// 同源（v1 envelope 门禁 + voice/panel 分发），改动须两处同步。
pragma ComponentBehavior: Bound
import QtQuick

Item {
    id: root

    // 宿主 C++ 注入上下文属性 Host：
    //   sendEnvelope(method, args) —— 控制通道回写（ready/select/hover/…）
    //   requestFrame()             —— 请求渲染一帧（宿主持有节流与合并）
    // theme{font_path} 的加载源（FontLoader 异步，失败回落系统默认）
    property string fontPath: ""

    Theme {
        id: themeObj
    }

    FontLoader {
        id: themeFontLoader
        source: root.fontPath === "" ? "" : "file://" + root.fontPath
        // 与 theme{font_family} 的显式指定后到者赢（原型简化）
        onNameChanged: themeObj.fontFamily = name
    }

    Card {
        id: card
        theme: themeObj
        onSelectRequested: index => Host.sendEnvelope("select",
                                                      { index: index })
        onHoverRequested: row => Host.sendEnvelope("hover", { row: row })
        onCancelRequested: () => Host.sendEnvelope("cancel", {})
    }

    Panel {
        id: panel
        theme: themeObj
        onSelectRequested: index => Host.sendEnvelope("select",
                                                      { index: index })
        onHoverRequested: row => Host.sendEnvelope("hover", { row: row })
        onNavigateRequested: delta => Host.sendEnvelope("navigate",
                                                        { delta: delta })
    }

    // 帧尺寸 = 活跃面的内在尺寸（theme.scale 已内化，位图即物理像素语义）。
    // 候选面板优先——与 ui_addon update() 的语音会话让位判定同语义
    width: panel.shown
               ? panel.implicitWidth
               : (card.mode !== "idle" ? card.implicitWidth : 0)
    height: panel.shown
                ? panel.implicitHeight
                : (card.mode !== "idle" ? card.implicitHeight : 0)

    property var caps: []
    property int recvCount: 0
    property int ignoredCount: 0

    // 录音态心跳：动画（录音点脉冲）不依赖 envelope 流也能走帧
    Timer {
        running: card.mode === "recording"
        interval: 120
        repeat: true
        onTriggered: Host.requestFrame()
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
            // 跟随锚定是 VoicePopup 的职责（合成器贴光标），本场景忽略
            break
        default:
            root.ignoredCount++ // 未知 method 忽略（向前兼容）
            return
        }
        root.recvCount++
        console.log("CARD: ENV seq=" + (env.seq === undefined ? -1 : env.seq)
                    + " method=" + env.method)
        Host.requestFrame()
    }
}
