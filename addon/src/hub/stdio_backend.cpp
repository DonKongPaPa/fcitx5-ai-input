#include "stdio_backend.h"

#include <fcitx-utils/log.h>

#include <fcntl.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cstdlib>

namespace fcitx {

StdioBackend::~StdioBackend() { terminate(); }

bool StdioBackend::spawn(EventLoop *loop, const std::string &cmd,
                         LineHandler onLine, ExitHandler onExit) {
    terminate();
    if (cmd.empty()) {
        return false;
    }
    onLine_ = std::move(onLine);
    onExit_ = std::move(onExit);
    buf_.clear();

    int inPipe[2];  // 我们 → 子进程 stdin
    int outPipe[2]; // 子进程 stdout → 我们
    if (pipe(inPipe) != 0 || pipe(outPipe) != 0) {
        FCITX_WARN() << "AiInput: [stdio] pipe 失败";
        return false;
    }
    pid_ = fork();
    if (pid_ == 0) {
        ::close(inPipe[1]);
        ::close(outPipe[0]);
        dup2(inPipe[0], 0);
        dup2(outPipe[1], 1);
        // stderr 直通：后端异常直接进 fcitx5 日志，排障第一现场
        ::close(inPipe[0]);
        ::close(outPipe[1]);
        execl("/bin/sh", "sh", "-c", cmd.c_str(), nullptr);
        _exit(127);
    }
    ::close(inPipe[0]);
    ::close(outPipe[1]);
    if (pid_ < 0) {
        FCITX_WARN() << "AiInput: [stdio] fork 失败";
        ::close(inPipe[1]);
        ::close(outPipe[0]);
        return false;
    }
    inFd_ = inPipe[1];
    outFd_ = outPipe[0];
    int flags = fcntl(outFd_, F_GETFL);
    fcntl(outFd_, F_SETFL, flags | O_NONBLOCK);
    watch_ = loop->addIOEvent(
        outFd_, IOEventFlag::In,
        [this](EventSourceIO *, int, IOEventFlags) {
            handleRead();
            return true;
        });
    FCITX_LOG(Info) << "AiInput: [stdio] 后端已启动 pid=" << pid_
                    << " cmd=" << cmd;
    return true;
}

void StdioBackend::handleRead() {
    char buf[4096];
    for (;;) {
        ssize_t n = read(outFd_, buf, sizeof(buf));
        if (n > 0) {
            buf_.append(buf, n);
            size_t pos = 0;
            while (true) {
                size_t e = buf_.find('\n', pos);
                if (e == std::string::npos) {
                    break;
                }
                std::string line = buf_.substr(pos, e - pos);
                while (!line.empty() && line.back() == '\r') {
                    line.pop_back();
                }
                if (!line.empty() && onLine_) {
                    onLine_(line);
                }
                pos = e + 1;
            }
            buf_.erase(0, pos);
            continue;
        }
        if (n == 0) {
            // EOF：子进程退出。半行残留按整行处理（后端崩在行中间）
            if (!buf_.empty() && onLine_) {
                onLine_(buf_);
                buf_.clear();
            }
            if (pid_ > 0) {
                int st = 0;
                if (waitpid(pid_, &st, WNOHANG) == 0) {
                    usleep(50000);
                    waitpid(pid_, &st, WNOHANG);
                }
                pid_ = -1;
            }
            watch_.reset();
            ::close(outFd_);
            outFd_ = -1;
            if (inFd_ >= 0) {
                ::close(inFd_);
                inFd_ = -1;
            }
            if (onExit_) {
                onExit_();
            }
            return;
        }
        if (errno == EINTR) {
            continue;
        }
        return; // EAGAIN
    }
}

bool StdioBackend::send(const std::string &line) {
    if (inFd_ < 0) {
        return false;
    }
    std::string out = line + "\n";
    size_t off = 0;
    while (off < out.size()) {
        ssize_t n = write(inFd_, out.data() + off, out.size() - off);
        if (n > 0) {
            off += n;
            continue;
        }
        if (n < 0 && (errno == EAGAIN || errno == EINTR)) {
            continue; // envelope 行远小于 pipe 缓冲，EAGAIN 实际不可达
        }
        FCITX_WARN() << "AiInput: [stdio] 写入失败（子进程断开？）";
        return false;
    }
    return true;
}

void StdioBackend::terminate() {
    watch_.reset();
    if (pid_ > 0) {
        kill(pid_, SIGTERM);
        int st = 0;
        if (waitpid(pid_, &st, WNOHANG) == 0) {
            usleep(50000);
            kill(pid_, SIGKILL);
            waitpid(pid_, &st, 0);
        }
        pid_ = -1;
    }
    if (inFd_ >= 0) {
        ::close(inFd_);
        inFd_ = -1;
    }
    if (outFd_ >= 0) {
        ::close(outFd_);
        outFd_ = -1;
    }
    buf_.clear();
}

} // namespace fcitx
