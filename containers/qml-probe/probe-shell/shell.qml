// qml-probe 探针卡片（Quickshell 0.3.2，宿主 qmltypes 审计对应的 API 形状）
// 验证点（lab/spec/protocol.md v1 envelope）：
//   A. PanelWindow 以 layer-shell 表面 map 到 niri（WlrLayer.Top / namespace aiinput-probe）
//   B. Quickshell.Io/Socket 连 Unix socket，SplitParser 按行收 envelope（wire=紧凑 JSON+\n）
//      协议 §8：ui 侧分发器只消费 channel=="ui" && dir=="out"，其余忽略
//   C. ui→addon 方向：收到 voice/candidates 后 write 回 select（写后需 flush）
//   D. map 后改 margins.top → height 即时变化（top+bottom 双锚 → h=输出高-top-bottom）
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
    id: root

    // feeder（python 回放器）的 socket 路径，由容器编排经环境变量传入
    property string sockPath: Quickshell.env("AIINPUT_PROBE_SOCK") !== ""
                              ? Quickshell.env("AIINPUT_PROBE_SOCK")
                              : "/run/user/1000/aiinput-probe.sock"
    property int recvCount: 0
    property int sendCount: 0
    property string lastMethod: "(等待 envelope)"

    PanelWindow {
        id: card
        visible: true
        color: "#1e1e2e"
        anchors { top: true; bottom: true; left: true }
        margins { left: 8; top: 10; bottom: 10 }
        exclusionMode: ExclusionMode.Ignore
        implicitWidth: 420

        // namespace 陷阱：windowConnected 之后不可再改（官方文档），故静态定死
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.namespace: "aiinput-probe"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        Rectangle {
            anchors.fill: parent
            anchors.margins: 12
            radius: 10
            color: "#313244"

            Column {
                anchors.centerIn: parent
                spacing: 10
                width: parent.width - 24

                Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    color: "#cdd6f4"
                    font.pixelSize: 15
                    text: "fcitx5-ai-input · Quickshell QML 卡片探针"
                }
                Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    color: "#89b4fa"
                    font.pixelSize: 13
                    text: "w=" + card.width + " h=" + card.height
                          + "  recv=" + root.recvCount + " send=" + root.sendCount
                }
                Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    color: "#a6e3a1"
                    font.pixelSize: 13
                    elide: Text.ElideMiddle
                    text: "last: " + root.lastMethod
                }
            }
        }

        property bool mapLogged: false
        property bool earlyLogged: false
        onWidthChanged: maybeLogMap()
        onHeightChanged: maybeLogMap()
        onVisibleChanged: maybeLogMap()
        Component.onCompleted: maybeLogMap()

        // A 的证据：visible && width/height>0 ⇔ compositor 已对 layer surface
        // 发 configure 并 commit（wayland layer-shell 语义），即 map 完成。
        // 实测 niri 会先给一次未含锚点的 configure（420x100），故以 h>=500
        // （top+bottom 双锚后的最终形态）判定最终 map
        function maybeLogMap() {
            if (!visible || width <= 0 || height <= 0)
                return
            if (!earlyLogged) {
                earlyLogged = true
                console.log("QS_PROBE: MAP_EARLY width=" + width + " height=" + height)
            }
            if (mapLogged || height < 500)
                return
            mapLogged = true
            console.log("QS_PROBE: MAP_OK layer=" + WlrLayershell.layer
                        + " width=" + width + " height=" + height
                        + " margins.top=" + margins.top)
            marginTimer.start()
        }

        // D. margins 即时性：map 后 1.2s 改 margins.top（10→130），不带任何重 map 动作
        Timer {
            id: marginTimer
            interval: 1200
            onTriggered: {
                console.log("QS_PROBE: MARGIN_BEFORE height=" + card.height
                            + " top=" + card.margins.top)
                card.margins.top = 130
                afterTimer.start()
            }
        }
        Timer {
            id: afterTimer
            interval: 700
            onTriggered: console.log("QS_PROBE: MARGIN_AFTER height=" + card.height
                                     + " top=" + card.margins.top)
        }
    }

    // B. Unix socket 客户端（Io 模块无读自身 stdin 的类型——qmltypes 审计结论）
    Socket {
        id: sock
        path: root.sockPath
        connected: true
        parser: SplitParser {
            onRead: line => root.handleLine(line)
        }
        onConnectionStateChanged: {
            console.log("QS_PROBE: SOCK connected=" + connected)
            if (connected) {
                retryTimer.stop()
                root.sendEnvelope("ready", {})
            }
        }
        onError: err => {
            console.log("QS_PROBE: SOCK_ERR code=" + err)
            retryTimer.restart()
        }
    }
    Timer {
        id: retryTimer
        interval: 600
        onTriggered: {
            sock.connected = false
            reconnectTimer.start()
        }
    }
    Timer {
        id: reconnectTimer
        interval: 200
        onTriggered: sock.connected = true
    }

    function handleLine(line) {
        if (!line || !line.trim())
            return
        var env
        try {
            env = JSON.parse(line)
        } catch (e) {
            console.log("QS_PROBE: BADJSON " + line.substring(0, 80))
            return
        }
        var dir = env.dir === undefined ? "?" : env.dir
        var ch = env.channel === undefined ? "?" : env.channel
        var seq = env.seq === undefined ? -1 : env.seq
        if (ch !== "ui" || dir !== "out") {
            console.log("QS_PROBE: IGNORED channel=" + ch + " dir=" + dir
                        + " seq=" + seq
                        + " method=" + (env.method === undefined ? "?" : env.method))
            return
        }
        root.recvCount++
        root.lastMethod = env.method + " seq=" + seq
        console.log("QS_PROBE: ENV seq=" + seq + " method=" + env.method)
        if (env.method === "voice/candidates") {
            // C. 演示 ui→addon：同一 socket 上回写（write 后须 flush）
            root.sendEnvelope("select", { index: 0 })
        } else if (env.method === "panel/update") {
            var cands = env.args && env.args.candidates ? env.args.candidates : []
            if (cands.length > 0)
                root.lastMethod = "panel/update [" + cands[0].text + "]"
        }
    }

    function sendEnvelope(method, args) {
        root.sendCount++
        var env = { v: 1, channel: "ui", dir: "in", method: method,
                    seq: 9000 + root.sendCount, args: args }
        sock.write(JSON.stringify(env) + "\n")
        sock.flush()
        console.log("QS_PROBE: SEND seq=" + env.seq + " method=" + method)
    }
}
