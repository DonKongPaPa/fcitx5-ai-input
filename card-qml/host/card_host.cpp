// card-qml/host/card_host.cpp —— aiinput-card-host：frame-relay 离屏渲染
// 宿主（lab/spec/frame-relay.md §2「渲染与定位分离」）。
//
// 职责单一：装载 QML 场景，状态面变化即渲染一帧 premultiplied BGRA，经帧
// socket 推给 VoicePopup；定位/表面生命周期全在 fcitx5 侧。独立进程 =
// 崩溃隔离（kill 不拖垮 fcitx5，SocketUi 单客户端语义负责重连恢复）。
//
// 为什么不用 quickshell：grabToImage 依赖合成器 expose（invisible/屏外窗口
// 回调永久丢失，wip/qml-frame-relay 分支存档）。本宿主 QQuickRenderControl
// + 软件后端全同步渲染，QT_QPA_PLATFORM=offscreen 不依赖任何显示服务器
//（字体照常走 fontconfig）。
//
// 传输（与 SocketUi 对接，见 socket_ui.cpp listenUnix 注释）：AIINPUT_CARD_
// SOCK = '/' 开头的 filesystem 路径，否则 abstract 名；帧通道 = 同名+
// "-frame"。abstract 无常驻 dentry（容器 flow 里 filesystem socket 的
// dentry 毫秒级被外部摘除），因此原生 AF_UNIX 而非 QLocalSocket——Qt 的
// QLocalSocket 对 abstract 名支持是未定文档行为。NONBLOCK + writeAll 短写
// 安全（候选帧可达数百 KB，超 socket 缓冲）。
//
// 尺寸语义：QML 场景内 theme.scale 已内化输出缩放（Card/Panel 全部度量乘
// scale），根 Item 的隐式尺寸即物理像素——无 dpr 协商。
//
// 帧格式（帧通道）：FRM u32le w u32le h u32le size '\n' BGRA8888 预乘。

#include <QGuiApplication>
#include <QCoreApplication>
#include <QImage>
#include <QMouseEvent>
#include <QJsonDocument>
#include <QJsonObject>
#include <QQuickItem>
#include <QQuickRenderControl>
#include <QQuickWindow>
#include <QSGRendererInterface>
#include <QSocketNotifier>
#include <QStringList>
#include <QTimer>
#include <QUrl>
#include <QVariantMap>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQmlEngine>

#include <QtGlobal>

#include <poll.h>
#include <sys/socket.h>
#include <sys/un.h>

#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <unistd.h>

namespace {

// 连接 SocketUi 监听端（'/' 开头 = filesystem 路径，否则 abstract 名；
// 本地 unix socket 连接即时完成，阻塞式即可）
int connectUnix(const std::string &name) {
    int fd = ::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    if (fd < 0) {
        return -1;
    }
    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    socklen_t len = 0;
    if (!name.empty() && name[0] == '/') {
        if (name.size() >= sizeof(addr.sun_path)) {
            ::close(fd);
            return -1;
        }
        strncpy(addr.sun_path, name.c_str(), sizeof(addr.sun_path) - 1);
        len = sizeof(addr);
    } else {
        if (name.size() + 1 >= sizeof(addr.sun_path)) {
            ::close(fd);
            return -1;
        }
        memcpy(addr.sun_path + 1, name.c_str(), name.size());
        len = static_cast<socklen_t>(offsetof(sockaddr_un, sun_path)) + 1 +
              name.size();
    }
    if (::connect(fd, reinterpret_cast<const sockaddr *>(&addr), len) != 0) {
        ::close(fd);
        return -1;
    }
    return fd;
}

// NONBLOCK socket 的短写安全发送（候选帧可达数百 KB，超缓冲时 poll 等可写）
bool writeAll(int fd, const char *data, size_t len) {
    while (len > 0) {
        ssize_t n = ::write(fd, data, len);
        if (n > 0) {
            data += n;
            len -= static_cast<size_t>(n);
            continue;
        }
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            pollfd p{fd, POLLOUT, 0};
            ::poll(&p, 1, -1);
            continue;
        }
        return false; // EPIPE 等：链路断，交由重连
    }
    return true;
}

// QML 桥（上下文属性 Host）：回写控制通道 + 声明需要新帧。节流与合并在
// C++ 侧（QML 只管「场景变了」，渲染节奏不归场景管）
class HostBridge : public QObject {
    Q_OBJECT
public:
    explicit HostBridge(QObject *parent = nullptr) : QObject(parent) {}

    void setCtrlFd(const int *fd) { ctrlFd_ = fd; }

    Q_INVOKABLE void sendEnvelope(const QString &method,
                                  const QVariantMap &args) {
        if (!ctrlFd_ || *ctrlFd_ < 0) {
            return;
        }
        QJsonObject obj;
        obj[QLatin1String("v")] = 1;
        obj[QLatin1String("channel")] = QLatin1String("ui");
        obj[QLatin1String("dir")] = QLatin1String("in");
        obj[QLatin1String("method")] = method;
        obj[QLatin1String("seq")] = ++seq_;
        obj[QLatin1String("args")] = QJsonObject::fromVariantMap(args);
        QByteArray wire = QJsonDocument(obj).toJson(QJsonDocument::Compact);
        wire.append('\n');
        writeAll(*ctrlFd_, wire.constData(),
                 static_cast<size_t>(wire.size()));
    }

    Q_INVOKABLE void requestFrame() { dirty_ = true; }

    bool dirty() const { return dirty_; }
    void clearDirty() { dirty_ = false; }

private:
    const int *ctrlFd_ = nullptr;
    int seq_ = 0;
    bool dirty_ = false;
};

} // namespace

int main(int argc, char **argv) {
    // 首行启动日志：spawn 上下文排障锚点（fcitx5 fork 后 exec 是否到达、
    // 何时到达，全靠它与 fcitx5 日志的时间戳对齐）
    std::fprintf(stderr, "CARD-HOST: start pid=%d\n", ::getpid());
    // 离屏平台 + 软件 API 都必须在首个 QQuickWindow 实例化前设定
    qputenv("QT_QPA_PLATFORM", "offscreen");
    QGuiApplication app(argc, argv);
    QQuickWindow::setGraphicsApi(QSGRendererInterface::Software);

    QString qmlDir = QStringLiteral("/usr/share/fcitx5-aiinput/card-qml");
    const QStringList args = app.arguments();
    for (int i = 1; i + 1 < args.size(); ++i) {
        if (args.at(i) == QLatin1String("--qml-dir")) {
            qmlDir = args.at(i + 1);
        }
    }
    std::string sockPath = "aiinput-card-1000";
    if (const char *env = std::getenv("AIINPUT_CARD_SOCK"); env && *env) {
        sockPath = env;
    }
    const std::string framePath = sockPath + "-frame";

    QQuickRenderControl renderControl;
    QQuickWindow window(&renderControl); // 永 map：离屏渲染无平台窗口
    // 窗口底色必须透明（默认白）：Card/Panel 圆角外的四角露出的是这层
    window.setColor(Qt::transparent);
    QQmlEngine qmlEngine;
    HostBridge hostBridge;
    qmlEngine.rootContext()->setContextProperty(QStringLiteral("Host"),
                                                &hostBridge);

    QQmlComponent component(
        &qmlEngine, QUrl::fromLocalFile(qmlDir + QStringLiteral("/shell-headless.qml")));
    QObject *rootObj = component.create();
    if (!rootObj || component.isError()) {
        for (const auto &e : component.errors()) {
            std::fprintf(stderr, "CARD-HOST: QML error: %s\n",
                         qPrintable(e.toString()));
        }
        return rootObj ? 0 : 1;
    }
    auto *rootItem = qobject_cast<QQuickItem *>(rootObj);
    if (!rootItem) {
        std::fprintf(stderr, "CARD-HOST: 场景根不是 Item\n");
        return 1;
    }
    rootObj->setParent(&window); // 收所有权防 QML GC 回收
    rootItem->setParentItem(window.contentItem());

    // —— 双通道（控制 + 帧）：断线即 600ms 重连（SocketUi 单客户端语义
    // 上会顶掉旧连接，重连即接管；ready 在控制通道连上即发）——
    int ctrlFd = -1;
    int frameFd = -1;
    QSocketNotifier *ctrlNotifier = nullptr;
    QSocketNotifier *frameNotifier = nullptr;
    QByteArray ctrlBuf;
    hostBridge.setCtrlFd(&ctrlFd);

    QTimer retry;
    retry.setInterval(600);
    retry.setSingleShot(true);

    auto closeFrame = [&]() {
        delete frameNotifier;
        frameNotifier = nullptr;
        if (frameFd >= 0) {
            ::close(frameFd);
            frameFd = -1;
        }
    };
    auto closeCtrl = [&]() {
        delete ctrlNotifier;
        ctrlNotifier = nullptr;
        if (ctrlFd >= 0) {
            ::close(ctrlFd);
            ctrlFd = -1;
        }
    };

    // panel/pointer：popup 表面指针 → 合成 Qt 鼠标事件进场景（relay 候选
    // hover/点击选择；QML 侧 Panel/Card 的 MouseArea 与 select/hover 回流
    // 本来就在，缺的只是事件注入）。坐标 = 表面逻辑坐标，scale=1 与帧像
    // 素 1:1
    auto handlePointerLine = [&window](const QByteArray &line) -> bool {
        if (line.size() < 2 || line.front() != '{') {
            return false;
        }
        QJsonParseError perr{};
        const auto doc = QJsonDocument::fromJson(line, &perr);
        if (perr.error != QJsonParseError::NoError || !doc.isObject()) {
            return false;
        }
        const auto obj = doc.object();
        if (obj[QLatin1String("method")].toString() !=
            QLatin1String("panel/pointer")) {
            return false;
        }
        const auto a = obj[QLatin1String("args")].toObject();
        const QString kind = a[QLatin1String("kind")].toString();
        const QPointF pos(a[QLatin1String("x")].toDouble(),
                          a[QLatin1String("y")].toDouble());
        QEvent::Type type = QEvent::None;
        Qt::MouseButton button = Qt::NoButton;
        Qt::MouseButtons buttons = Qt::NoButton;
        if (kind == QLatin1String("motion")) {
            type = QEvent::MouseMove;
        } else if (kind == QLatin1String("press")) {
            type = QEvent::MouseButtonPress;
            button = Qt::LeftButton;
            buttons = Qt::LeftButton;
        } else if (kind == QLatin1String("release")) {
            type = QEvent::MouseButtonRelease;
            button = Qt::LeftButton;
        } else {
            return true; // enter/leave：Qt 由 move 自合成
        }
        QMouseEvent ev(type, pos, pos, button, buttons, Qt::NoModifier);
        QCoreApplication::sendEvent(&window, &ev);
        return true;
    };

    auto onCtrlReadable = [&]() {
        char chunk[4096];
        for (;;) {
            ssize_t n = ::read(ctrlFd, chunk, sizeof(chunk));
            if (n > 0) {
                ctrlBuf.append(chunk, static_cast<qsizetype>(n));
                qsizetype pos;
                while ((pos = ctrlBuf.indexOf('\n')) >= 0) {
                    QByteArray line = ctrlBuf.left(pos);
                    ctrlBuf.remove(0, pos + 1);
                    if (line.trimmed().isEmpty()) {
                        continue;
                    }
                    if (handlePointerLine(line)) {
                        continue;
                    }
                    QMetaObject::invokeMethod(rootItem, "handleLine",
                                              Q_ARG(QVariant,
                                                    QString::fromUtf8(line)));
                }
                continue;
            }
            if (n == 0 || (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK)) {
                std::fprintf(stderr, "CARD-HOST: control 断开，600ms 重连\n");
                closeCtrl();
                retry.start();
            }
            break;
        }
    };
    auto onFrameReadable = [&]() {
        // 服务端不回数据：可读即 EOF/错误，按断开处理
        char sink[256];
        ssize_t n = ::read(frameFd, sink, sizeof(sink));
        if (n == 0 || (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK)) {
            std::fprintf(stderr, "CARD-HOST: frame 断开，600ms 重连\n");
            closeFrame();
            retry.start();
        }
    };

    auto tryConnect = [&]() {
        if (ctrlFd < 0) {
            if (int fd = connectUnix(sockPath); fd >= 0) {
                ctrlFd = fd;
                ctrlNotifier = new QSocketNotifier(fd, QSocketNotifier::Read);
                QObject::connect(ctrlNotifier, &QSocketNotifier::activated,
                                 onCtrlReadable);
                std::fprintf(stderr, "CARD-HOST: control connected %s\n",
                             sockPath.c_str());
                hostBridge.sendEnvelope(QStringLiteral("ready"), QVariantMap{});
            }
        }
        if (frameFd < 0) {
            if (int fd = connectUnix(framePath); fd >= 0) {
                frameFd = fd;
                frameNotifier = new QSocketNotifier(fd, QSocketNotifier::Read);
                QObject::connect(frameNotifier, &QSocketNotifier::activated,
                                 onFrameReadable);
                std::fprintf(stderr, "CARD-HOST: frame connected %s\n",
                             framePath.c_str());
            }
        }
    };
    QObject::connect(&retry, &QTimer::timeout, tryConnect);

    // —— 渲染泵：30ms 合并窗口内的 requestFrame 渲染成一帧 ——
    QTimer renderTick;
    renderTick.setInterval(30);
    renderTick.start();
    QObject::connect(&renderTick, &QTimer::timeout, [&]() {
        if (!hostBridge.dirty()) {
            return;
        }
        hostBridge.clearDirty();
        const int w = qRound(rootItem->width());
        const int h = qRound(rootItem->height());
        // idle（两活跃面皆空）：尺寸 0，不发帧（表面生命周期在 popup 侧）
        if (w <= 0 || h <= 0 || w > 4096 || h > 4096) {
            return;
        }
        if (window.width() != w || window.height() != h) {
            window.setGeometry(0, 0, w, h);
        }
        // 软件 + rendercontrol 的渲染序列（Qt 文档次序）；软件后端的位图
        // 经 grabWindow 读回（ARGB32_Premultiplied，小端内存即 BGRA 预乘）
        renderControl.polishItems();
        renderControl.sync();
        renderControl.beginFrame();
        renderControl.render();
        renderControl.endFrame();
        QImage img = window.grabWindow();
        if (img.isNull()) {
            std::fprintf(stderr, "CARD-HOST: grab 空图 w=%d h=%d\n", w, h);
            return;
        }
        img = img.convertToFormat(QImage::Format_ARGB32_Premultiplied);
        if (frameFd < 0) {
            return; // 帧通道未连：丢帧（下帧全量覆盖，协议无回执语义）
        }
        const quint32 wu = static_cast<quint32>(img.width());
        const quint32 hu = static_cast<quint32>(img.height());
        const quint32 su = static_cast<quint32>(img.sizeInBytes());
        QByteArray header;
        header.reserve(16);
        header.append("FRM", 3);
        header.append(reinterpret_cast<const char *>(&wu), 4);
        header.append(reinterpret_cast<const char *>(&hu), 4);
        header.append(reinterpret_cast<const char *>(&su), 4);
        header.append('\n');
        const char *payload =
            reinterpret_cast<const char *>(img.constBits());
        if (!writeAll(frameFd, header.constData(),
                      static_cast<size_t>(header.size())) ||
            !writeAll(frameFd, payload, static_cast<size_t>(img.sizeInBytes()))) {
            std::fprintf(stderr, "CARD-HOST: frame 写失败，600ms 重连\n");
            closeFrame();
            retry.start();
            return;
        }
        std::fprintf(stderr, "CARD-HOST: frame %dx%d %uB\n", img.width(),
                     img.height(), su);
    });

    tryConnect();
    return app.exec();
}

#include "card_host.moc"
