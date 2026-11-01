// card-qml/Panel.qml —— rime/拼音候选面板（协议 §4.1 panel/*，classicui 等价数据形状）
// preedit 分段 underline、aux_up/aux_down、candidates(label/text/comment)、
// horizontal/vertical 双布局、cursor 键盘高亮、hover 高亮、翻页（按钮+滚轮）。
// panel/update 为全量推送：缺省字段复位为默认，不保留旧值。
pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Material

Rectangle {
    id: panel

    required property Theme theme

    // panelWindow.visible 绑定此值：panel/update 显示、panel/hide 隐藏
    property bool shown: false
    // hello 协商的能力位：翻页控件仅 caps 含 paging 时可见
    property var caps: []

    property var preedit: [] // [{text, underline}]
    property string auxUp: ""
    property string auxDown: ""
    property var candidates: [] // [{label, text, comment?}]
    property int cursor: -1 // 键盘光标（页内索引，classicui 语义）
    property string layoutMode: "horizontal" // horizontal | vertical
    property bool hasPrev: false
    property bool hasNext: false
    property int page: 0
    property string imName: ""

    // —— ui→addon（协议 §4.2，shell.qml 转发）——
    signal selectRequested(int index)
    signal hoverRequested(int row)
    signal navigateRequested(int delta)

    readonly property int pad: Math.round(10 * theme.scale)
    implicitWidth: Math.round(720 * theme.scale)
    implicitHeight: content.implicitHeight + 2 * pad
    radius: theme.radius
    color: theme.surfaceContainer
    opacity: 0.97

    Material.theme: Material.Dark
    Material.primary: theme.primary
    Material.background: theme.surfaceContainer

    // 滚轮翻页：向上滚 = 上一页（navigate{delta:-1}）
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.NoButton
        onWheel: wheel => panel.navigateRequested(
                     wheel.angleDelta.y > 0 ? -1 : 1)
    }

    Column {
        id: content
        anchors.fill: parent
        anchors.margins: panel.pad
        spacing: Math.round(6 * panel.theme.scale)

        Row {
            spacing: Math.round(8 * panel.theme.scale)
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: panel.imName
                color: panel.theme.onSurfaceVariant
                font.family: panel.theme.fontFamily
                font.pixelSize: panel.theme.fontSize - 2
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "第 " + (panel.page + 1) + " 页"
                color: panel.theme.onSurfaceVariant
                font.family: panel.theme.fontFamily
                font.pixelSize: panel.theme.fontSize - 2
            }
            Button {
                anchors.verticalCenter: parent.verticalCenter
                visible: panel.caps.includes("paging")
                text: "◀"
                enabled: panel.hasPrev
                onClicked: panel.navigateRequested(-1)
            }
            Button {
                anchors.verticalCenter: parent.verticalCenter
                visible: panel.caps.includes("paging")
                text: "▶"
                enabled: panel.hasNext
                onClicked: panel.navigateRequested(1)
            }
        }

        Text {
            visible: panel.auxUp !== ""
            text: panel.auxUp
            color: panel.theme.onSurfaceVariant
            font.family: panel.theme.fontFamily
            font.pixelSize: panel.theme.fontSize
        }

        Row {
            spacing: 0
            Repeater {
                model: panel.preedit
                delegate: Text {
                    required property var modelData
                    text: modelData.text
                    color: panel.theme.onSurface
                    font.family: panel.theme.fontFamily
                    font.pixelSize: panel.theme.fontSize + 2
                    // underline 段底部划线（classicui PreEdit underline 等价）
                    Rectangle {
                        anchors.bottom: parent.bottom
                        width: parent.width
                        height: 2
                        radius: 1
                        color: panel.theme.primary
                        visible: modelData.underline === true
                    }
                }
            }
        }

        Text {
            visible: panel.auxDown !== ""
            text: panel.auxDown
            color: panel.theme.onSurfaceVariant
            font.family: panel.theme.fontFamily
            font.pixelSize: panel.theme.fontSize
        }

        Flow {
            width: parent.width
            visible: panel.layoutMode === "horizontal"
            spacing: Math.round(6 * panel.theme.scale)
            Repeater {
                model: panel.candidates
                delegate: PanelCand {}
            }
        }

        Column {
            width: parent.width
            visible: panel.layoutMode === "vertical"
            spacing: Math.round(2 * panel.theme.scale)
            Repeater {
                model: panel.candidates
                delegate: PanelCand {}
            }
        }
    }

    // inline component 供横/竖两个 Repeater 复用
    component PanelCand: Rectangle {
        required property var modelData
        required property int index
        // 行号 = 页内索引 = select{index} / hover{row} 的行号
        readonly property bool active: candArea.containsMouse
                                       || panel.cursor === index
        width: candRow.implicitWidth + Math.round(16 * panel.theme.scale)
        height: candRow.implicitHeight + Math.round(8 * panel.theme.scale)
        radius: Math.round(6 * panel.theme.scale)
        color: active ? panel.theme.surfaceVariant : "transparent"
        border.width: panel.cursor === index ? 1 : 0
        border.color: panel.theme.primary
        Row {
            id: candRow
            anchors.centerIn: parent
            spacing: Math.round(4 * panel.theme.scale)
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.label !== undefined ? modelData.label : ""
                color: panel.theme.primary
                font.family: panel.theme.fontFamily
                font.pixelSize: panel.theme.fontSize
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.text
                color: panel.theme.onSurface
                font.family: panel.theme.fontFamily
                font.pixelSize: panel.theme.fontSize
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: modelData.comment !== undefined
                         && modelData.comment !== ""
                text: modelData.comment !== undefined ? modelData.comment : ""
                color: panel.theme.outline
                font.family: panel.theme.fontFamily
                font.pixelSize: panel.theme.fontSize - 2
            }
        }
        MouseArea {
            id: candArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onEntered: panel.hoverRequested(index)
            onClicked: panel.selectRequested(index)
        }
    }

    // —— 事件入口（shell.qml 分发调用；全量推送，缺省字段复位）——
    function applyUpdate(args) {
        preedit = args.preedit === undefined ? [] : args.preedit
        auxUp = args.aux_up === undefined ? "" : args.aux_up
        auxDown = args.aux_down === undefined ? "" : args.aux_down
        candidates = args.candidates === undefined ? [] : args.candidates
        cursor = args.cursor === undefined ? -1 : args.cursor
        layoutMode = args.layout === undefined ? "horizontal" : args.layout
        hasPrev = args.has_prev === true
        hasNext = args.has_next === true
        page = args.page === undefined ? 0 : args.page
        imName = args.im_name === undefined ? "" : args.im_name
        shown = true
    }
    function hidePanel() {
        shown = false
    }
}
