#define _GNU_SOURCE 1
#include "ui_bridge.h"

#include "popup_surface.h"

#include <fcitx-utils/log.h>

#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cstdlib>
#include <cstring>

extern char **environ;

namespace fcitx {

// JSON 字符串转义（UTF-8 原样透传）
static std::string jsonEscape(const std::string &s) {
    std::string out;
    out.reserve(s.size() + 2);
    for (unsigned char c : s) {
        switch (c) {
        case '"': out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\n': out += "\\n"; break;
        case '\r': out += "\\r"; break;
        case '\t': out += "\\t"; break;
        default:
            if (c < 0x20) {
                char buf[8];
                snprintf(buf, sizeof(buf), "\\u%04x", c);
                out += buf;
            } else {
                out += static_cast<char>(c);
            }
        }
    }
    return out;
}

UiBridge::UiBridge(Instance *instance, VoicePopup *popup)
    : instance_(instance), popup_(popup) {}

UiBridge::~UiBridge() {
    closeClient();
    if (listenFd_ >= 0) {
        close(listenFd_);
        listenFd_ = -1;
    }
    if (childPid_ > 0) {
        kill(childPid_, SIGTERM);
        // 非阻塞收尸（避免阻塞析构；残留 zombie 由 init 回收）
        waitpid(childPid_, nullptr, WNOHANG);
        childPid_ = -1;
    }
}

bool UiBridge::processAlive() const {
    return childPid_ > 0 && waitpid(childPid_, nullptr, WNOHANG) == 0;
}

bool UiBridge::ensureStarted() {
    if (spawnFailed_) {
        return false;
    }
    if (processAlive() && listenFd_ >= 0) {
        return true;
    }
    // 进程死了：清理旧监听与子进程状态后重启
    if (childPid_ > 0) {
        waitpid(childPid_, nullptr, WNOHANG);
        childPid_ = -1;
    }
    if (listenFd_ < 0 && !startListener()) {
        return false;
    }
    return spawnUi();
}

bool UiBridge::startListener() {
    listenFd_ = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (listenFd_ < 0) {
        FCITX_WARN() << "UiBridge: socket() failed: " << strerror(errno);
        return false;
    }
    int one = 1;
    setsockopt(listenFd_, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0; // 临时端口
    if (bind(listenFd_, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) <
            0 ||
        listen(listenFd_, 1) < 0) {
        FCITX_WARN() << "UiBridge: bind/listen failed: " << strerror(errno);
        close(listenFd_);
        listenFd_ = -1;
        return false;
    }
    socklen_t len = sizeof(addr);
    getsockname(listenFd_, reinterpret_cast<sockaddr *>(&addr), &len);
    port_ = ntohs(addr.sin_port);
    listenEvent_ = instance_->eventLoop().addIOEvent(
        listenFd_, IOEventFlag::In,
        [this](EventSourceIO *, int, IOEventFlags) {
            onAcceptable();
            return true;
        });
    FCITX_INFO() << "UiBridge: listening on 127.0.0.1:" << port_;
    return true;
}

static std::vector<std::string> buildEnv(int port) {
    std::vector<std::string> env;
    for (char **e = environ; e && *e; ++e) {
        env.emplace_back(*e);
    }
    // flutter 窗口宿主：专用无头合成器（测试环境注入；缺省继承当前显示）
    const char *uiDisplay = getenv("VOICEINPUT_UI_DISPLAY");
    auto setEnv = [&env](const std::string &kv) {
        auto key = kv.substr(0, kv.find('='));
        for (auto &s : env) {
            if (s.rfind(key + "=", 0) == 0) {
                s = kv;
                return;
            }
        }
        env.push_back(kv);
    };
    if (uiDisplay && *uiDisplay) {
        setEnv("WAYLAND_DISPLAY=" + std::string(uiDisplay));
    }
    setEnv("GDK_BACKEND=wayland");
    setEnv("VOICEINPUT_BRIDGE_HOST=127.0.0.1");
    setEnv("VOICEINPUT_BRIDGE_PORT=" + std::to_string(port));
    return env;
}

bool UiBridge::spawnUi() {
    const char *exe = VOICEINPUT_UI_PATH;
    if (access(exe, X_OK) != 0) {
        FCITX_WARN() << "UiBridge: UI binary missing: " << exe
                     << "（回退 F3 色块模式）";
        spawnFailed_ = true;
        return false;
    }
    auto env = buildEnv(port_);
    std::vector<char *> envp;
    for (auto &s : env) {
        envp.push_back(s.data());
    }
    envp.push_back(nullptr);

    int logFd = open("/tmp/voiceinput-ui.log",
                     O_WRONLY | O_CREAT | O_TRUNC, 0644);
    childPid_ = fork();
    if (childPid_ == 0) {
        // 子进程：脱离会话，stdio → 日志文件
        setsid();
        if (logFd >= 0) {
            dup2(logFd, 1);
            dup2(logFd, 2);
        } else {
            int devnull = open("/dev/null", O_WRONLY);
            if (devnull >= 0) {
                dup2(devnull, 1);
                dup2(devnull, 2);
            }
        }
        char *const argv[] = {const_cast<char *>(exe), nullptr};
        execve(exe, argv, envp.data());
        _exit(127);
    }
    if (logFd >= 0) {
        close(logFd);
    }
    if (childPid_ < 0) {
        FCITX_WARN() << "UiBridge: fork failed: " << strerror(errno);
        childPid_ = -1;
        return false;
    }
    const char *logDisplay = getenv("VOICEINPUT_UI_DISPLAY");
    FCITX_INFO() << "UiBridge: flutter UI spawned pid=" << childPid_
                 << " port=" << port_
                 << " WAYLAND_DISPLAY="
                 << (logDisplay && *logDisplay ? logDisplay : "(inherit)")
                 << " XDG_RUNTIME_DIR="
                 << (getenv("XDG_RUNTIME_DIR")
                         ? getenv("XDG_RUNTIME_DIR")
                         : "(null)");
    return true;
}

void UiBridge::onAcceptable() {
    if (clientFd_ >= 0) {
        return; // 单客户端：已有连接则拒绝（accept 后立刻关）
    }
    int fd = accept4(listenFd_, nullptr, nullptr,
                     SOCK_NONBLOCK | SOCK_CLOEXEC);
    if (fd < 0) {
        return;
    }
    clientFd_ = fd;
    rbuf_.clear();
    clientEvent_ = instance_->eventLoop().addIOEvent(
        clientFd_, IOEventFlag::In,
        [this](EventSourceIO *, int, IOEventFlags) {
            onReadable();
            return true;
        });
    FCITX_INFO() << "UiBridge: flutter UI connected";
}

// 简易 JSON 数值提取（帧头格式固定，由 flutter 侧拼装）
static bool scanKeyInt(const char *s, const char *key, int *out) {
    const char *p = strstr(s, key);
    if (!p) {
        return false;
    }
    p += strlen(key);
    char *end = nullptr;
    long v = strtol(p, &end, 10);
    if (end == p) {
        return false;
    }
    *out = static_cast<int>(v);
    return true;
}

void UiBridge::onReadable() {
    uint8_t chunk[65536];
    for (;;) {
        ssize_t n = recv(clientFd_, chunk, sizeof(chunk), 0);
        if (n > 0) {
            rbuf_.insert(rbuf_.end(), chunk, chunk + n);
            continue;
        }
        if (n == 0) {
            FCITX_INFO() << "UiBridge: flutter UI disconnected";
            closeClient();
            return;
        }
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            break;
        }
        if (errno == EINTR) {
            continue;
        }
        closeClient();
        return;
    }
    parseBuffer(rbuf_);
}

void UiBridge::parseBuffer(std::vector<uint8_t> &buf) {
    for (;;) {
        auto nl = std::find(buf.begin(), buf.end(), '\n');
        if (nl == buf.end()) {
            return; // 头不完整
        }
        std::string header(buf.begin(), nl);
        int w = 0, h = 0, len = 0;
        if (strstr(header.c_str(), "\"frame\"") &&
            scanKeyInt(header.c_str(), "\"w\":", &w) &&
            scanKeyInt(header.c_str(), "\"h\":", &h) &&
            scanKeyInt(header.c_str(), "\"len\":", &len)) {
            size_t headerLen = nl - buf.begin() + 1;
            if (buf.size() - headerLen < static_cast<size_t>(len)) {
                return; // 帧体不完整，等更多数据
            }
            if (len == w * h * 4 && w > 0 && h > 0) {
                popup_->pushFrame(buf.data() + headerLen, w, h);
            } else {
                FCITX_WARN() << "UiBridge: bad frame " << w << "x" << h
                             << " len=" << len;
            }
            buf.erase(buf.begin(), buf.begin() + headerLen + len);
        } else {
            // 未知行式消息：跳过该行
            buf.erase(buf.begin(), nl + 1);
        }
    }
}

void UiBridge::closeClient() {
    clientEvent_.reset();
    if (clientFd_ >= 0) {
        close(clientFd_);
        clientFd_ = -1;
    }
    rbuf_.clear();
}

void UiBridge::sendState(const std::string &line) {
    if (clientFd_ < 0) {
        return;
    }
    std::string msg = line + "\n";
    ssize_t rc = ::send(clientFd_, msg.data(), msg.size(), MSG_NOSIGNAL);
    if (rc < 0 && (errno == EPIPE || errno == ECONNRESET)) {
        closeClient();
    }
}

void UiBridge::sendRecording(const std::string &partial, uint64_t elapsedMs) {
    sendState("{\"type\":\"state\",\"state\":\"recording\",\"partial\":\"" +
              jsonEscape(partial) + "\",\"elapsed_ms\":" +
              std::to_string(elapsedMs) + "}");
}

void UiBridge::sendResult(const std::string &finalText, int timeoutMs) {
    sendState("{\"type\":\"state\",\"state\":\"result\",\"final\":\"" +
              jsonEscape(finalText) + "\",\"timeout_ms\":" +
              std::to_string(timeoutMs) + "}");
}

void UiBridge::sendCandidates(const std::string &finalText,
                              const std::vector<std::string> &candidates,
                              int hover) {
    std::string list;
    for (size_t i = 0; i < candidates.size(); ++i) {
        if (i) {
            list += ",";
        }
        list += "\"" + jsonEscape(candidates[i]) + "\"";
    }
    sendState(
        "{\"type\":\"state\",\"state\":\"candidates\",\"final\":\"" +
        jsonEscape(finalText) + "\",\"hover\":" + std::to_string(hover) +
        ",\"candidates\":[" + list + "]}");
}

void UiBridge::sendIdle() { sendState("{\"type\":\"state\",\"state\":\"idle\"}"); }

} // namespace fcitx
