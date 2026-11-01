#include "socket_ui.h"

#include "json_util.h"
#include "proto_line.h"

#include <fcitx-utils/log.h>

#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <cstddef>
#include <cerrno>
#include <cstdlib>

#include <fcntl.h>
#include <signal.h>

namespace fcitx {

namespace {

// AF_UNIX bind/listen：'/' 开头 = filesystem 路径（旧约定）；否则 =
// abstract 名（sun_path[0]='\0'）。容器 flow 里 filesystem socket 的
// dentry 在 bind 后毫秒级被外部摘除（内核 socket 表仍在监听、连 bind 者
// 自己的路径查找都 ENOENT），abstract 无常驻 dentry，从根上免疫该类
// 竞态；作用域 = netns，与 fcitx5 会话同界
bool listenUnix(int fd, const std::string &name) {
    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    socklen_t len = 0;
    if (!name.empty() && name[0] == '/') {
        if (name.size() >= sizeof(addr.sun_path)) {
            return false;
        }
        strncpy(addr.sun_path, name.c_str(), sizeof(addr.sun_path) - 1);
        len = sizeof(addr);
    } else {
        if (name.size() + 1 >= sizeof(addr.sun_path)) {
            return false;
        }
        memcpy(addr.sun_path + 1, name.c_str(), name.size());
        len = static_cast<socklen_t>(offsetof(sockaddr_un, sun_path)) + 1 +
              name.size();
    }
    return bind(fd, reinterpret_cast<const sockaddr *>(&addr), len) == 0 &&
           listen(fd, 2) == 0;
}

} // namespace

// 从 "args":{ 起做括号配对，取完整对象体（行协议无转义大括号——envelope
// 的字符串值经 flutterJsonEscape 不转义 {}，但候选文本含 {} 的概率与代价
// 都低；原型期以配对计数为准，失败返回空）
static std::string extractArgsObject(const std::string &line) {
    auto pos = jsonValuePos(line, "args");
    if (pos == std::string::npos || pos >= line.size() || line[pos] != '{') {
        return "";
    }
    int depth = 0;
    for (size_t i = pos; i < line.size(); ++i) {
        if (line[i] == '{') {
            ++depth;
        } else if (line[i] == '}') {
            if (--depth == 0) {
                return line.substr(pos, i - pos + 1);
            }
        }
    }
    return "";
}

SocketUi::SocketUi(Instance *instance, const std::string &sockPath,
                   const std::string &spawnCmd, bool relayMode,
                   LineHandler onLine, FrameHandler onFrame)
    : instance_(instance), sockPath_(sockPath), onLine_(std::move(onLine)),
      onFrame_(std::move(onFrame)), framePath_(sockPath + "-frame"),
      relayMode_(relayMode) {
    serverFd_ = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    if (serverFd_ < 0) {
        FCITX_WARN() << "AiInputUi: socket 卡片监听创建失败 errno=" << errno;
        return;
    }
    const bool fsSock = !sockPath_.empty() && sockPath_[0] == '/';
    if (fsSock) {
        unlink(sockPath_.c_str()); // 残留 sock 文件（上次异常退出）先清
    }
    if (!listenUnix(serverFd_, sockPath_)) {
        FCITX_WARN() << "AiInputUi: socket 卡片 bind/listen 失败 errno="
                     << errno;
        close(serverFd_);
        serverFd_ = -1;
        return;
    }
    serverWatch_ = instance_->eventLoop().addIOEvent(
        serverFd_, IOEventFlag::In, [this](EventSourceIO *, int, IOEventFlags) {
            acceptClient();
            return true;
        });
    // —— 帧通道（frame-relay，lab/spec/frame-relay.md）：第二 socket 纯
    // 二进制（FRM 头 + PPM payload），与行协议互不阻塞 ——
    frameServerFd_ = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    if (frameServerFd_ >= 0) {
        if (fsSock) {
            unlink(framePath_.c_str());
        }
        if (listenUnix(frameServerFd_, framePath_)) {
            frameServerWatch_ = instance_->eventLoop().addIOEvent(
                frameServerFd_, IOEventFlag::In,
                [this](EventSourceIO *, int, IOEventFlags) {
                    acceptFrameClient();
                    return true;
                });
        } else {
            close(frameServerFd_);
            frameServerFd_ = -1;
        }
    }

    FCITX_INFO() << "AiInputUi: QML 卡片 socket 监听就绪 " << sockPath_
                 << (frameServerFd_ >= 0 ? "（帧通道就绪 " + framePath_ + "）"
                                         : "（帧通道未建）");

    if (!spawnCmd.empty()) {
        // 拉起 QML 卡（继承 fcitx5 的会话 env：WAYLAND_DISPLAY 等齐备；
        // stderr 直通 fcitx5 日志）。卡片退出不重启——对比期手动重跑
        if (pid_t pid = fork(); pid == 0) {
            setsid();
            // socket 路径与渲染模式显式交接给卡片（不依赖 QML 默认值）
            setenv("AIINPUT_CARD_SOCK", sockPath_.c_str(), 1);
            // relay 模式（FlutterCard=False）：QML 直显窗口退场，卡片帧
            // 全部经 popup 上屏（防双显；invisible 窗口 grab 有效性见
            // frame-relay.md §4 验证点）
            setenv("AIINPUT_CARD_RELAY", relayMode_ ? "1" : "0", 1);
            // stdout/stderr 都继承：qs 的 INFO/ERROR/CARD 行直通 fcitx5
            // 日志（排障第一现场）；stdin 挂 /dev/null（卡片不读 stdin）
            int devnullr = open("/dev/null", O_RDONLY);
            if (devnullr >= 0) {
                dup2(devnullr, 0);
            }
            execl("/bin/sh", "sh", "-c", spawnCmd.c_str(), nullptr);
            _exit(127);
        } else if (pid > 0) {
            spawnPid_ = pid;
        }
        FCITX_INFO() << "AiInputUi: QML 卡片已拉起（" << spawnCmd
                     << "，sock=" << sockPath_ << "）";
    }
}

SocketUi::~SocketUi() {
    if (spawnPid_ > 0) {
        kill(spawnPid_, SIGTERM);
    }
    detachFrameClient();
    if (frameServerWatch_) {
        frameServerWatch_.reset();
    }
    if (frameServerFd_ >= 0) {
        close(frameServerFd_);
    }
    const bool fsSock = !sockPath_.empty() && sockPath_[0] == '/';
    if (fsSock) {
        unlink(framePath_.c_str());
    }
    detachClient();
    if (serverWatch_) {
        serverWatch_.reset();
    }
    if (serverFd_ >= 0) {
        close(serverFd_);
    }
    if (fsSock) {
        unlink(sockPath_.c_str());
    }
}

void SocketUi::acceptClient() {
    int fd = accept4(serverFd_, nullptr, nullptr,
                     SOCK_CLOEXEC | SOCK_NONBLOCK);
    if (fd < 0) {
        return;
    }
    // 单客户端：新连接顶掉旧连接（对比期一张卡；卡片断线重连即此路径）
    detachClient();
    clientFd_ = fd;
    clientWatch_ = instance_->eventLoop().addIOEvent(
        clientFd_, IOEventFlag::In,
        [this](EventSourceIO *, int, IOEventFlags) {
            handleClientRead();
            return true;
        });
    FCITX_INFO() << "AiInputUi: QML 卡片已连接";
}

void SocketUi::detachClient() {
    if (clientWatch_) {
        clientWatch_.reset();
    }
    if (clientFd_ >= 0) {
        close(clientFd_);
        clientFd_ = -1;
    }
    buf_.clear();
}

void SocketUi::handleClientRead() {
    char chunk[4096];
    ssize_t n;
    while ((n = read(clientFd_, chunk, sizeof(chunk))) > 0) {
        buf_.append(chunk, static_cast<size_t>(n));
        size_t pos;
        while ((pos = buf_.find('\n')) != std::string::npos) {
            std::string line = buf_.substr(0, pos);
            buf_.erase(0, pos + 1);
            if (line.empty()) {
                continue;
            }
            if (onLine_) {
                onLine_(envelopeMethod(line), extractArgsObject(line));
            }
        }
    }
    if (n == 0 || (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK)) {
        FCITX_INFO() << "AiInputUi: QML 卡片断开（等待重连）";
        detachClient();
    }
}

void SocketUi::acceptFrameClient() {
    int fd = accept4(frameServerFd_, nullptr, nullptr,
                     SOCK_CLOEXEC | SOCK_NONBLOCK);
    if (fd < 0) {
        return;
    }
    detachFrameClient();
    frameFd_ = fd;
    frameBuf_.clear();
    frameExpect_ = 0;
    frameWatch_ = instance_->eventLoop().addIOEvent(
        frameFd_, IOEventFlag::In,
        [this](EventSourceIO *, int, IOEventFlags) {
            handleFrameRead();
            return true;
        });
    FCITX_INFO() << "AiInputUi: QML 卡片帧通道已连接";
}

void SocketUi::detachFrameClient() {
    if (frameWatch_) {
        frameWatch_.reset();
    }
    if (frameFd_ >= 0) {
        close(frameFd_);
        frameFd_ = -1;
    }
    frameBuf_.clear();
    frameExpect_ = 0;
}

void SocketUi::handleFrameRead() {
    char chunk[65536];
    ssize_t n;
    while ((n = read(frameFd_, chunk, sizeof(chunk))) > 0) {
        frameBuf_.append(chunk, static_cast<size_t>(n));
        // FRM 帧协议："FRM" u32le w u32le h u32le size '\n' payload[size]
        for (;;) {
            if (frameExpect_ == 0) {
                static constexpr size_t kHead = 3 + 12 + 1;
                if (frameBuf_.size() < kHead ||
                    frameBuf_.compare(0, 3, "FRM") != 0) {
                    break;
                }
                uint32_t w, h, size;
                memcpy(&w, frameBuf_.data() + 3, 4);
                memcpy(&h, frameBuf_.data() + 7, 4);
                memcpy(&size, frameBuf_.data() + 11, 4);
                if (size == 0 || size > 64u * 1024 * 1024) {
                    FCITX_WARN() << "AiInputUi: 帧尺寸异常 " << size;
                    detachFrameClient();
                    return;
                }
                frameExpect_ = size;
                frameW_ = w;
                frameH_ = h;
                frameBuf_.erase(0, kHead);
            }
            if (frameBuf_.size() < frameExpect_) {
                break;
            }
            if (onFrame_) {
                onFrame_(static_cast<int>(frameW_), static_cast<int>(frameH_),
                         reinterpret_cast<const uint8_t *>(frameBuf_.data()),
                         frameExpect_);
            }
            frameBuf_.erase(0, frameExpect_);
            frameExpect_ = 0;
        }
    }
    if (n == 0 || (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK)) {
        FCITX_INFO() << "AiInputUi: QML 卡片帧通道断开（等待重连）";
        detachFrameClient();
    }
}

void SocketUi::feedFrame(const uint8_t *data, size_t len) {}

void SocketUi::sendEnvelope(const std::string &method,
                            const std::string &argsJson) {
    if (clientFd_ < 0) {
        return; // 卡片未连接：静默丢弃（协议无回执语义，全量重推保证）
    }
    std::string wire = "{\"v\":1,\"channel\":\"ui\",\"dir\":\"out\",\"method\":\"" +
                       method + "\",\"args\":" +
                       (argsJson.empty() ? "{}" : argsJson) + "}\n";
    FCITX_LOG(Info) << "AiInputUi: [sock->] fd=" << clientFd_ << " "
                    << method << " " << wire.size() << "B";
    // 行协议小包，主循环直写；短写视为链路异常由下次读事件清理
    auto n = write(clientFd_, wire.data(), wire.size());
    if (n < 0) {
        FCITX_WARN() << "AiInputUi: QML 卡片写失败 errno=" << errno;
    } else {
        FCITX_LOG(Info) << "AiInputUi: [sock->] wrote " << n;
    }
}

} // namespace fcitx
