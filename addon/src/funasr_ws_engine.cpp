#define _GNU_SOURCE 1
#include "funasr_ws_engine.h"

#include "audio_capture.h"
#include "voiceinput_config.h"

#include <fcitx-utils/log.h>

#include <arpa/inet.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cstring>

namespace fcitx {

static constexpr int kFinalTimeoutSec = 30; // GPU 首推理 JIT 慢（final 可达 14s）

static uint64_t nowUs() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<uint64_t>(ts.tv_sec) * 1000000 + ts.tv_nsec / 1000;
}

// ws://host:port 解析
static bool parseUrl(const std::string &url, std::string *host, int *port) {
    auto prefix = url.rfind("ws://", 0);
    if (prefix != 0) {
        return false;
    }
    auto rest = url.substr(5);
    auto colon = rest.rfind(':');
    if (colon == std::string::npos) {
        *host = rest;
        *port = 80;
    } else {
        *host = rest.substr(0, colon);
        *port = atoi(rest.c_str() + colon + 1);
    }
    return !host->empty() && *port > 0;
}

static void b64(const uint8_t *in, size_t n, char *out) {
    static const char T[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    size_t o = 0;
    for (size_t i = 0; i < n; i += 3) {
        uint32_t v = in[i] << 16;
        if (i + 1 < n) v |= in[i + 1] << 8;
        if (i + 2 < n) v |= in[i + 2];
        out[o++] = T[(v >> 18) & 63];
        out[o++] = T[(v >> 12) & 63];
        out[o++] = (i + 1 < n) ? T[(v >> 6) & 63] : '=';
        out[o++] = (i + 2 < n) ? T[v & 63] : '=';
    }
    out[o] = 0;
}

void FunAsrWsEngine::start(EventLoop *loop, const VoiceInputConfig *config,
                           Callbacks cbs) {
    loop_ = loop;
    config_ = config;
    cbs_ = std::move(cbs);
    finished_ = false;
    gotFinal_ = false;

    std::string host;
    int port = 0;
    if (!parseUrl(config->funasrUrl.value(), &host, &port)) {
        FCITX_WARN() << "FunAsrWs: URL 无效 " << config->funasrUrl.value();
        finishSession("");
        return;
    }
    // 采集立即启动：连接建立前的音频缓存（preConnAudio_），不丢开头
    capture_ = std::make_unique<AudioCapture>();
    if (!capture_->start(loop_, [this](const uint8_t *d, size_t n) {
            if (sockFd_ < 0) {
                preConnAudio_.insert(preConnAudio_.end(), d, d + n);
                return;
            }
            // 攒 ~100ms（3200 字节）发一帧，减少 syscall；
            // 发送失败（服务端忙、缓冲满）丢弃该块（final 兜底全量识别）
            pending_.insert(pending_.end(), d, d + n);
            chunkAccum_ += n;
            if (chunkAccum_ >= 3200) {
                if (!sendWsFrame(false, pending_.data(), pending_.size())) {
                    ++dropCount_;
                    if (dropCount_ == 1 || dropCount_ % 50 == 0) {
                        FCITX_LOG(Info)
                            << "FunAsrWs: 音频块丢弃 " << dropCount_
                            << "（服务端忙，识别将以 final 为准）";
                    }
                }
                pending_.clear();
                chunkAccum_ = 0;
            }
        })) {
        FCITX_WARN() << "FunAsrWs: parec 启动失败";
        finishSession("");
        return;
    }

    if (!connectServer(host, port) || !wsHandshake()) {
        close(sockFd_);
        sockFd_ = -1;
        // FunASRAutoStart：按配置拉起服务后异步重连（模型加载 ~15-60s）
        if (config->funasrAutoStart.value() &&
            !config->funasrServerCmd.value().empty()) {
            trySpawnServer();
            scheduleReconnect();
            return;
        }
        FCITX_WARN() << "FunAsrWs: connect " << config->funasrUrl.value()
                     << " failed（服务未启动？scripts/funasr-serve.sh start）";
        finishSession("");
        return;
    }
    onConnected();
}

void FunAsrWsEngine::onConnected() {
    std::string host;
    int port = 0;
    parseUrl(config_->funasrUrl.value(), &host, &port);
    // 握手完成后转非阻塞：服务端推理忙时接收缓冲满，阻塞 write 会冻住
    // fcitx5 主循环（可冻结数十秒）——音频块宁可丢弃（final 兜底），
    // 控制帧走定时重试
    {
        int nb = fcntl(sockFd_, F_GETFL);
        fcntl(sockFd_, F_SETFL, nb | O_NONBLOCK);
    }
    FCITX_INFO() << "FunAsrWs: connected " << host << ":" << port;

    // 首帧：语言配置
    sendText("{\"language\":\"" + config_->funasrLanguage.value() + "\"}");

    sockEv_ = loop_->addIOEvent(
        sockFd_, IOEventFlag::In,
        [this](EventSourceIO *, int, IOEventFlags) {
            onSocketReadable();
            return true;
        });

    // 连接前缓存的音频补发
    if (!preConnAudio_.empty()) {
        sendWsFrame(false, preConnAudio_.data(), preConnAudio_.size());
        preConnAudio_.clear();
    }
}

void FunAsrWsEngine::trySpawnServer() {
    if (spawned_) {
        return;
    }
    spawned_ = true;
    std::string host;
    int port = 0;
    parseUrl(config_->funasrUrl.value(), &host, &port);
    const char *dev = "auto";
    switch (config_->funasrDevice.value()) {
    case FunASRDeviceKind::Gpu: dev = "gpu"; break;
    case FunASRDeviceKind::Cpu: dev = "cpu"; break;
    default: break;
    }
    std::string quant =
        config_->funasrQuant.value() == FunASRQuantKind::Int8 ? "int8" : "";
    pid_t pid = fork();
    if (pid == 0) {
        setsid();
        int devnull = open("/dev/null", O_WRONLY);
        if (devnull >= 0) {
            dup2(devnull, 1);
            dup2(devnull, 2);
        }
        std::string p = std::to_string(port);
        std::string qs = quant;
        const std::string &cmd = config_->funasrServerCmd.value();
        char *const argv[] = {const_cast<char *>(cmd.c_str()), nullptr};
        // 传参约定见 funasr-serve.sh（FUNASR_PORT/DEVICE/QUANT）
        setenv("FUNASR_PORT", p.c_str(), 1);
        setenv("FUNASR_DEVICE", dev, 1);
        setenv("FUNASR_QUANT", qs.c_str(), 1);
        execv(cmd.c_str(), argv);
        _exit(127);
    }
    FCITX_INFO() << "FunAsrWs: FunASRAutoStart 拉起服务 pid=" << pid
                 << " device=" << dev << " quant=" << (quant.empty() ? "无" : quant)
                 << " cmd=" << config_->funasrServerCmd.value()
                 << "（模型加载 ~15-60s，期间音频缓存）";
}

void FunAsrWsEngine::scheduleReconnect() {
    if (finished_) {
        return;
    }
    // 2s 周期重连，~45s 上限（CPU 档加载 60s+ 时留给 final 超时兜底）
    if (++reconnectCount_ > 22) {
        FCITX_WARN() << "FunAsrWs: 自动拉起后重连超时";
        finishSession("");
        return;
    }
    reconnectTimer_ = loop_->addTimeEvent(
        CLOCK_MONOTONIC, nowUs() + 2 * 1000000, 0,
        [this](EventSourceTime *, uint64_t) {
            std::string host;
            int port = 0;
            if (parseUrl(config_->funasrUrl.value(), &host, &port) &&
                connectServer(host, port) && wsHandshake()) {
                onConnected();
                return false;
            }
            if (sockFd_ >= 0) {
                close(sockFd_);
                sockFd_ = -1;
            }
            // 时间事件严格一次性：defer 链再挂下一个
            reconnectDefer_ = loop_->addDeferEvent([this](EventSource *) {
                scheduleReconnect();
                return true;
            });
            return false;
        });
}

bool FunAsrWsEngine::connectServer(const std::string &host, int port) {
    sockFd_ = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (sockFd_ < 0) {
        return false;
    }
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    if (inet_pton(AF_INET, host.c_str(), &addr.sin_addr) != 1) {
        // host 是域名（如 host.containers.internal）：同步解析（本地网关，快）
        hostent *he = gethostbyname(host.c_str());
        if (!he || he->h_addrtype != AF_INET) {
            return false;
        }
        memcpy(&addr.sin_addr, he->h_addr_list[0], 4);
    }
    // 本地/网关链路：同步 connect（几十 ms 级）
    if (connect(sockFd_, reinterpret_cast<sockaddr *>(&addr),
                sizeof(addr)) != 0) {
        close(sockFd_);
        sockFd_ = -1;
        return false;
    }
    int one = 1;
    setsockopt(sockFd_, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    return true;
}

bool FunAsrWsEngine::wsHandshake() {
    uint8_t rnd[16];
    int ur = open("/dev/urandom", O_RDONLY);
    read(ur, rnd, sizeof(rnd));
    close(ur);
    char key[25];
    b64(rnd, 16, key);

    std::string host;
    int port;
    parseUrl(config_->funasrUrl.value(), &host, &port);
    std::string req = "GET / HTTP/1.1\r\nHost: " + host +
                      "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                      "Sec-WebSocket-Key: " +
                      key +
                      "\r\nSec-WebSocket-Version: 13\r\n\r\n";
    if (write(sockFd_, req.data(), req.size()) < 0) {
        return false;
    }
    // 读到响应头结束（本地服务，同步读可接受）
    std::string resp;
    char buf[1024];
    while (resp.find("\r\n\r\n") == std::string::npos &&
           resp.size() < sizeof(buf)) {
        ssize_t n = read(sockFd_, buf, sizeof(buf));
        if (n <= 0) {
            return false;
        }
        resp.append(buf, n);
    }
    return resp.rfind(" 101 ", 0) != std::string::npos ||
           resp.find("HTTP/1.1 101") != std::string::npos;
}

// 客户端帧必须 mask；fin=1，opcode: 1=text 2=binary
// 非阻塞写：EAGAIN/部分写时返回 false（调用方决定丢弃或重试）
bool FunAsrWsEngine::sendWsFrame(bool text, const uint8_t *payload,
                                 size_t len) {
    if (sockFd_ < 0) {
        return false;
    }
    uint8_t hdr[14];
    size_t h = 0;
    hdr[h++] = 0x80 | (text ? 0x1 : 0x2);
    uint8_t mask[4];
    int ur = open("/dev/urandom", O_RDONLY);
    read(ur, mask, 4);
    close(ur);
    if (len < 126) {
        hdr[h++] = 0x80 | static_cast<uint8_t>(len);
    } else if (len <= 0xffff) {
        hdr[h++] = 0x80 | 126;
        hdr[h++] = (len >> 8) & 0xff;
        hdr[h++] = len & 0xff;
    } else {
        hdr[h++] = 0x80 | 127;
        for (int i = 0; i < 8; ++i) {
            hdr[h++] = 0; // 长度 < 2^32，高 4 字节为 0
        }
        hdr[h++] = (len >> 24) & 0xff;
        hdr[h++] = (len >> 16) & 0xff;
        hdr[h++] = (len >> 8) & 0xff;
        hdr[h++] = len & 0xff;
    }
    memcpy(hdr + h, mask, 4);
    h += 4;

    std::vector<uint8_t> masked(len);
    for (size_t i = 0; i < len; ++i) {
        masked[i] = payload[i] ^ mask[i & 3];
    }
    size_t sent = 0;
    while (sent < h) {
        ssize_t n = write(sockFd_, hdr + sent, h - sent);
        if (n < 0) {
            return false; // EAGAIN：整帧放弃（调用方策略）
        }
        sent += n;
    }
    size_t done = 0;
    while (done < len) {
        ssize_t n = write(sockFd_, masked.data() + done, len - done);
        if (n < 0) {
            return false; // 帧不完整：对音频可容忍（丢块），对控制帧由重试兜底
        }
        done += n;
    }
    return true;
}

void FunAsrWsEngine::onSocketReadable() {
    uint8_t buf[16384];
    static bool dbgDumped = false; // 调试：首个到达分片
    for (;;) {
        ssize_t n = recv(sockFd_, buf, sizeof(buf), 0);
        if (n > 0) {
            if (!dbgDumped) {
                dbgDumped = true;
                std::string hex;
                for (int i = 0; i < n && i < 16; ++i) {
                    char b[4];
                    snprintf(b, sizeof(b), "%02x ", buf[i]);
                    hex += b;
                }
                FCITX_INFO() << "FunAsrWs: first recv " << n << "B: " << hex;
            }
            feedRecvBuffer(buf, n);
            continue;
        }
        if (n == 0) {
            FCITX_INFO() << "FunAsrWs: server closed";
            if (!gotFinal_) {
                finishSession("");
            }
            return;
        }
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            return;
        }
        if (errno == EINTR) {
            continue;
        }
        if (!gotFinal_) {
            finishSession("");
        }
        return;
    }
}

// WS 帧重组：服务端帧不 mask
void FunAsrWsEngine::feedRecvBuffer(uint8_t *data, size_t len) {
    recvBuf_.insert(recvBuf_.end(), data, data + len);
    for (;;) {
        if (recvBuf_.size() < 2) {
            return;
        }
        uint8_t op = recvBuf_[0] & 0x0f;
        bool masked = recvBuf_[1] & 0x80;
        uint64_t plen = recvBuf_[1] & 0x7f;
        size_t header = 2;
        if (plen == 126) {
            if (recvBuf_.size() < 4) return;
            plen = (recvBuf_[2] << 8) | recvBuf_[3];
            header = 4;
        } else if (plen == 127) {
            if (recvBuf_.size() < 10) return;
            plen = 0;
            for (int i = 2; i < 10; ++i) {
                plen = (plen << 8) | recvBuf_[i];
            }
            header = 10;
        }
        if (masked) {
            header += 4; // 服务端帧不应 mask，防御性跳过
        }
        if (recvBuf_.size() < header + plen) {
            return;
        }
        if (op == 0x1) { // text
            handleTextMessage(
                std::string(recvBuf_.begin() + header,
                            recvBuf_.begin() + header + plen));
        }
        // op 0x8 close / 0x9 ping：本地服务不发，忽略
        recvBuf_.erase(recvBuf_.begin(), recvBuf_.begin() + header + plen);
    }
}

// 极简 JSON 字段提取（消息格式由本仓库 server.py 固定；容忍冒号后空白）
static bool jsonGetStr(const std::string &s, const char *key,
                       std::string *out) {
    std::string pat = std::string("\"") + key + "\"";
    auto p = s.find(pat);
    if (p == std::string::npos) {
        return false;
    }
    p = s.find(':', p + pat.size());
    if (p == std::string::npos) {
        return false;
    }
    ++p;
    while (p < s.size() && (s[p] == ' ' || s[p] == '\t')) {
        ++p;
    }
    if (p >= s.size() || s[p] != '"') {
        return false;
    }
    ++p;
    auto e = s.find('"', p);
    if (e == std::string::npos) {
        return false;
    }
    *out = s.substr(p, e - p);
    return true;
}

static bool jsonGetBool(const std::string &s, const char *key) {
    std::string pat = std::string("\"") + key + "\"";
    auto p = s.find(pat);
    if (p == std::string::npos) {
        return false;
    }
    p = s.find(':', p + pat.size());
    if (p == std::string::npos) {
        return false;
    }
    ++p;
    while (p < s.size() && (s[p] == ' ' || s[p] == '\t')) {
        ++p;
    }
    return s.compare(p, 4, "true") == 0;
}

void FunAsrWsEngine::handleTextMessage(const std::string &msg) {
    std::string text;
    jsonGetStr(msg, "text", &text);
    if (jsonGetBool(msg, "is_final")) {
        finishSession(text);
    } else if (!text.empty() && cbs_.onPartial && !finished_) {
        cbs_.onPartial(text);
    }
}

void FunAsrWsEngine::scheduleFinalTimeout() {
    uint64_t us = static_cast<uint64_t>(kFinalTimeoutSec) * 1000000;
    finalTimer_ = loop_->addTimeEvent(
        CLOCK_MONOTONIC, nowUs() + us, 0,
        [this](EventSourceTime *, uint64_t) {
            if (!gotFinal_) {
                FCITX_WARN() << "FunAsrWs: final 超时，取最后 partial 收尾";
                finishSession("");
            }
            return false;
        });
}

void FunAsrWsEngine::stop() {
    if (finished_) {
        return;
    }
    if (capture_) {
        capture_->stop();
    }
    if (sockFd_ >= 0) {
        // is_speaking=false 必须送达：非阻塞下可能 EAGAIN，200ms 周期重试
        //（时间事件严格一次性：经 defer 链再挂下一个，回调外替换自身安全）
        stopSent_ = sendText("{\"is_speaking\":false}");
        scheduleStopRetry();
        scheduleFinalTimeout();
        // 继续等 socket 上的 final（onSocketReadable → finishSession）
    }
}

void FunAsrWsEngine::scheduleStopRetry() {
    if (stopSent_ || finished_) {
        return;
    }
    stopRetryTimer_ = loop_->addTimeEvent(
        CLOCK_MONOTONIC, nowUs() + 200 * 1000, 0,
        [this](EventSourceTime *, uint64_t) {
            if (!finished_) {
                stopSent_ = sendText("{\"is_speaking\":false}");
            }
            if (!stopSent_ && !finished_) {
                stopDefer_ = loop_->addDeferEvent([this](EventSource *) {
                    scheduleStopRetry();
                    return true;
                });
            }
            return false;
        });
}

void FunAsrWsEngine::cancel() {
    finished_ = true;
    teardownAll();
}

void FunAsrWsEngine::finishSession(const std::string &text) {
    if (finished_) {
        return;
    }
    finished_ = true;
    gotFinal_ = true;
    teardownAll();
    if (cbs_.onFinish) {
        cbs_.onFinish(text);
    }
}

void FunAsrWsEngine::teardownAll() {
    finalTimer_.reset();
    stopRetryTimer_.reset();
    stopDefer_.reset();
    reconnectTimer_.reset();
    reconnectDefer_.reset();
    sockEv_.reset();
    if (capture_) {
        capture_->stop();
        capture_.reset();
    }
    if (sockFd_ >= 0) {
        close(sockFd_);
        sockFd_ = -1;
    }
    recvBuf_.clear();
    pending_.clear();
}

} // namespace fcitx
