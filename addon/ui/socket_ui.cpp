#include "socket_ui.h"

#include "json_util.h"
#include "proto_line.h"

#include <fcitx-utils/log.h>

#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <cerrno>
#include <cstdlib>

#include <fcntl.h>
#include <signal.h>

namespace fcitx {

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
                   const std::string &spawnCmd, LineHandler onLine)
    : instance_(instance), sockPath_(sockPath), onLine_(std::move(onLine)) {
    serverFd_ = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    if (serverFd_ < 0) {
        FCITX_WARN() << "AiInputUi: socket 卡片监听创建失败 errno=" << errno;
        return;
    }
    unlink(sockPath_.c_str()); // 残留 sock 文件（上次异常退出）先清
    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    if (sockPath_.size() >= sizeof(addr.sun_path)) {
        FCITX_WARN() << "AiInputUi: socket 路径过长 " << sockPath_;
        close(serverFd_);
        serverFd_ = -1;
        return;
    }
    strncpy(addr.sun_path, sockPath_.c_str(), sizeof(addr.sun_path) - 1);
    if (bind(serverFd_, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) !=
            0 ||
        listen(serverFd_, 2) != 0) {
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

    if (!spawnCmd.empty()) {
        // 拉起 QML 卡（继承 fcitx5 的会话 env：WAYLAND_DISPLAY 等齐备；
        // stderr 直通 fcitx5 日志）。卡片退出不重启——对比期手动重跑
        if (pid_t pid = fork(); pid == 0) {
            setsid();
            int devnull = open("/dev/null", O_WRONLY);
            if (devnull >= 0) {
                dup2(devnull, 1);
            }
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
    detachClient();
    if (serverWatch_) {
        serverWatch_.reset();
    }
    if (serverFd_ >= 0) {
        close(serverFd_);
    }
    unlink(sockPath_.c_str());
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

void SocketUi::sendEnvelope(const std::string &method,
                            const std::string &argsJson) {
    if (clientFd_ < 0) {
        return; // 卡片未连接：静默丢弃（协议无回执语义，全量重推保证）
    }
    std::string wire = "{\"v\":1,\"channel\":\"ui\",\"dir\":\"out\",\"method\":\"" +
                       method + "\",\"args\":" +
                       (argsJson.empty() ? "{}" : argsJson) + "}\n";
    // 行协议小包，主循环直写；短写视为链路异常由下次读事件清理
    if (write(clientFd_, wire.data(), wire.size()) < 0) {
        FCITX_WARN() << "AiInputUi: QML 卡片写失败 errno=" << errno;
    }
}

} // namespace fcitx
