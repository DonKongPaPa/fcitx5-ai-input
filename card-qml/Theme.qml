// card-qml/Theme.qml —— Material 暗色 tokens（QtQuick.Controls.Material 暗色调色板取值）
// 可行原型：色板定死暗色（决策② DMS Material 观感），不实现亮色切换。
// theme 事件（协议 §4.1）热改 baseFontSize/scale/anim；字号有效值=font_size×scale；
// anim 为速度挡位（1.0/1.6/3.0），动画时长=基准/anim，挡位越大越快。
pragma ComponentBehavior: Bound
import QtQuick

QtObject {
    id: theme

    // Material 3 dark palette（qt6 Material style 默认值）
    readonly property color primary: "#D0BCFF"
    readonly property color textOnPrimary: "#381E72"
    readonly property color surface: "#1C1B1F"
    readonly property color surfaceContainer: "#211F26"
    readonly property color surfaceContainerHigh: "#2B2930"
    readonly property color surfaceVariant: "#49454F"
    readonly property color textOnSurface: "#E6E1E5"
    readonly property color textOnSurfaceVariant: "#CAC4D0"
    readonly property color outline: "#938F99"
    readonly property color error: "#F2B8B5"

    // 语义色：录音指示点（Material tertiary dark）
    readonly property color recordingDot: "#EFB8C8"

    // —— theme 事件可写字段（shell.qml 写入）——
    property int baseFontSize: 16
    property real scale: 1.0
    property real anim: 1.0
    // 自定义字体：font_path 经 FontLoader 加载、font_family 直接指定，
    // 两者后到者赢（原型简化，不做优先级仲裁）
    property string fontFamily: ""

    readonly property int fontSize: Math.max(10, Math.round(baseFontSize * scale))
    readonly property int radius: Math.round(12 * scale)
    readonly property int animMs: Math.round(200 / (anim > 0 ? anim : 1.0))
}
