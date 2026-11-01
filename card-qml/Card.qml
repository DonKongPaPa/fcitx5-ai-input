// card-qml/Card.qml —— 语音卡四态（协议 §4.1 voice/*，事件即状态全量驱动）
// recording=partial+elapsed、result=final+自动上屏倒计时、candidates=列表+hover、
// idle=待机胶囊。倒计时是本地走表的视觉件（协议不回推剩余时间），到 0 不发
// 任何 ui→addon 命令：上屏决策在 addon（无回执语义）。
pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Material

Rectangle {
    id: card

    required property Theme theme

    // —— voice/* 事件数据面（shell.qml 经 show*() 写入）——
    property string mode: "idle" // idle | recording | result | candidates
    property string partial: ""
    property int elapsedMs: 0
    property string finalText: ""
    property int timeoutMs: 0
    property var candidates: [] // voice/candidates 的 string[]
    property int hoverRow: -1
    property bool llmDummy: false
    // result 态倒计时余量（仅视觉）
    property int remainMs: 0

    // —— ui→addon（协议 §4.2，shell.qml 转发）——
    signal selectRequested(int index)
    signal hoverRequested(int row)
    signal cancelRequested()

    readonly property int pad: Math.round(12 * theme.scale)
    implicitWidth: Math.round(420 * theme.scale)
    implicitHeight: content.implicitHeight + 2 * pad
    radius: theme.radius
    color: theme.surfaceContainer

    Material.theme: Material.Dark
    Material.primary: theme.primary
    Material.background: theme.surfaceContainer

    Column {
        id: content
        anchors.fill: parent
        anchors.margins: card.pad
        spacing: Math.round(8 * card.theme.scale)

        Row {
            spacing: Math.round(8 * card.theme.scale)
            Rectangle {
                // 录音指示点：recording 态按 anim 挡位脉动
                anchors.verticalCenter: parent.verticalCenter
                width: Math.round(10 * card.theme.scale)
                height: width
                radius: width / 2
                color: card.mode === "recording"
                           ? card.theme.recordingDot : card.theme.outline
                SequentialAnimation on scale {
                    running: card.mode === "recording"
                    loops: Animation.Infinite
                    NumberAnimation { to: 1.6; duration: card.theme.animMs }
                    NumberAnimation { to: 1.0; duration: card.theme.animMs }
                }
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                color: card.theme.textOnSurfaceVariant
                font.family: card.theme.fontFamily
                font.pixelSize: card.theme.fontSize
                text: card.mode === "recording"
                          ? "录音中 " + card.fmtElapsed(card.elapsedMs)
                      : card.mode === "result"
                          ? "识别完成 · 自动上屏 " + (card.remainMs / 1000).toFixed(1) + "s"
                      : card.mode === "candidates"
                          ? (card.llmDummy ? "候选 · dummy 润色" : "候选")
                          : "待机 · 长按触发键开始"
            }
        }

        Text {
            width: parent.width
            visible: card.mode !== "idle"
            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
            maximumLineCount: 3
            elide: Text.ElideRight
            color: card.theme.textOnSurface
            font.family: card.theme.fontFamily
            font.pixelSize: card.theme.fontSize + 2
            text: card.mode === "recording" ? card.partial : card.finalText
        }

        Column {
            width: parent.width
            visible: card.mode === "candidates"
            spacing: Math.round(4 * card.theme.scale)
            Repeater {
                model: card.candidates
                delegate: Rectangle {
                    id: cand
                    required property var modelData
                    required property int index
                    width: parent.width
                    height: candText.implicitHeight + Math.round(10 * card.theme.scale)
                    radius: Math.round(6 * card.theme.scale)
                    // 悬停高亮：本地 hover 与 voice/candidates 推来的 hover 行同源
                    color: candArea.containsMouse || card.hoverRow === index
                               ? card.theme.surfaceVariant : "transparent"
                    Text {
                        id: candText
                        anchors.verticalCenter: parent.verticalCenter
                        x: Math.round(8 * card.theme.scale)
                        width: parent.width - 2 * x
                        elide: Text.ElideRight
                        color: card.theme.textOnSurface
                        font.family: card.theme.fontFamily
                        font.pixelSize: card.theme.fontSize
                        text: (index + 1) + ". " + modelData
                    }
                    MouseArea {
                        id: candArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onEntered: {
                            card.hoverRow = index
                            card.hoverRequested(index)
                        }
                        onExited: if (card.hoverRow === index) card.hoverRow = -1
                        onClicked: card.selectRequested(index)
                    }
                }
            }
        }

        Row {
            visible: card.mode === "result" || card.mode === "candidates"
            // layer 表面无键盘焦点，Esc 不可达：原型以按钮发 cancel
            Button {
                text: "取消"
                onClicked: card.cancelRequested()
            }
        }
    }

    Timer {
        id: countTimer
        interval: 100
        repeat: true
        onTriggered: {
            card.remainMs = Math.max(0, card.remainMs - interval)
            if (card.remainMs === 0)
                stop()
        }
    }

    function fmtElapsed(ms) {
        var s = ms / 1000.0
        if (s >= 60) {
            var m = Math.floor(s / 60)
            var r = Math.floor(s % 60)
            return m + ":" + (r < 10 ? "0" : "") + r
        }
        return s.toFixed(1) + "s"
    }

    // —— 事件入口（shell.qml 分发调用；全量推送语义，直接覆盖不合并）——
    function showRecording(p, elapsed) {
        countTimer.stop()
        mode = "recording"
        partial = p
        elapsedMs = elapsed
    }
    function showResult(final, timeout) {
        mode = "result"
        finalText = final
        timeoutMs = timeout
        remainMs = timeout
        if (timeout > 0)
            countTimer.restart()
        else
            countTimer.stop()
    }
    function showCandidates(final, cands, hover, dummy) {
        countTimer.stop()
        mode = "candidates"
        finalText = final
        candidates = cands
        hoverRow = hover
        llmDummy = dummy
    }
    function showIdle() {
        countTimer.stop()
        mode = "idle"
        partial = ""
        candidates = []
        hoverRow = -1
        remainMs = 0
    }
}
