#ifndef _FCITX5_AIINPUT_STDIO_BACKEND_H_
#define _FCITX5_AIINPUT_STDIO_BACKEND_H_

#include <fcitx-utils/event.h>

#include <functional>
#include <memory>
#include <string>

namespace fcitx {

/**
 * v1 协议 stdio 传输：spawn 子进程，stdin/stdout 换行分隔的 envelope。
 * ASR / refine 后端共用；hello/版本协商由使用方按各自事件表发送。
 *
 * 子进程契约（lab/spec/protocol.md）：读 "dir":"out" 行、写 "dir":"in"
 * 行；未知 method 必须忽略；stderr 直通 fcitx5 日志（排障用）。
 */
class StdioBackend {
public:
    // 每收到一个完整行调用（不含换行）；EOF/子进程退出调 onExit
    using LineHandler = std::function<void(const std::string &line)>;
    using ExitHandler = std::function<void()>;

    ~StdioBackend();
    bool spawn(EventLoop *loop, const std::string &cmd, LineHandler onLine,
               ExitHandler onExit);
    bool running() const { return pid_ > 0; }
    // 写一行 envelope（自动补 '\n'）；管道断开返回 false
    bool send(const std::string &line);
    // SIGTERM + 关管道 + 收尸（阻塞 waitpid，子进程即退时毫秒级）
    void terminate();

private:
    void handleRead();
    pid_t pid_ = -1;
    int inFd_ = -1;  // 我们写、子进程读（child stdin）
    int outFd_ = -1; // 子进程写、我们读（child stdout）
    std::unique_ptr<EventSourceIO> watch_;
    LineHandler onLine_;
    ExitHandler onExit_;
    std::string buf_;
};

} // namespace fcitx

#endif // _FCITX5_AIINPUT_STDIO_BACKEND_H_
