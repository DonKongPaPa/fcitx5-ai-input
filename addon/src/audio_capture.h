#ifndef _FCITX5_VOICEINPUT_AUDIO_CAPTURE_H_
#define _FCITX5_VOICEINPUT_AUDIO_CAPTURE_H_

#include <fcitx-utils/event.h>

#include <fcntl.h>
#include <sys/wait.h>
#include <unistd.h>

#include <functional>

namespace fcitx {

/**
 * 麦克风采集：parec 子进程（16k/mono/s16le 原始 PCM → stdout）。
 *
 * 测试环境默认 source 已被 setup_virtual_mic 指到 vi_mic.monitor
 * （null-sink 虚拟麦）；真实桌面即默认输入设备。全部经 fcitx 主事件循环
 * （IOEvent），无额外线程。
 */
class AudioCapture {
public:
    using ChunkCb = std::function<void(const uint8_t *data, size_t len)>;

    ~AudioCapture() { stop(); }

    bool start(EventLoop *loop, ChunkCb onChunk) {
        loop_ = loop;
        onChunk_ = std::move(onChunk);
        int fds[2];
        if (pipe(fds) != 0) {
            return false;
        }
        pid_ = fork();
        if (pid_ == 0) {
            ::close(fds[0]);
            dup2(fds[1], 1);
            int devnull = open("/dev/null", O_WRONLY);
            if (devnull >= 0) {
                dup2(devnull, 2);
            }
            char *const argv[] = {
                const_cast<char *>("parec"),
                const_cast<char *>("--format=s16le"),
                const_cast<char *>("--rate=16000"),
                const_cast<char *>("--channels=1"),
                nullptr,
            };
            execvp("parec", argv);
            _exit(127);
        }
        ::close(fds[1]);
        if (pid_ < 0) {
            ::close(fds[0]);
            return false;
        }
        fd_ = fds[0];
        // 扩管道到 1MB（≈30s 音频）：模型加载/主循环卡顿期间音频缓冲在
        // 管道里不丢（默认 64KB 只够 ~2s，模型加载 ~1s 即可淹没）
        fcntl(fd_, F_SETPIPE_SZ, 1 << 20);
        int flags = fcntl(fd_, F_GETFL);
        fcntl(fd_, F_SETFL, flags | O_NONBLOCK);
        ev_ = loop_->addIOEvent(
            fd_, IOEventFlag::In,
            [this](EventSourceIO *, int, IOEventFlags) {
                onReadable();
                return true;
            });
        return true;
    }

    void stop() {
        ev_.reset();
        // 尾音 drain：先把管道里未读走的音频全部读出（继续回调引擎，
        // 否则松键瞬间的数百毫秒语音被直接丢弃——sherpa final 缺尾字
        // 的根因），SIGTERM 后再读一轮子进程退出前的余量
        if (fd_ >= 0) {
            drainPipe();
        }
        if (pid_ > 0) {
            kill(pid_, SIGTERM);
            if (fd_ >= 0) {
                drainPipe();
            }
            waitpid(pid_, nullptr, WNOHANG);
            pid_ = -1;
        }
        if (fd_ >= 0) {
            ::close(fd_);
            fd_ = -1;
        }
    }

private:
    void drainPipe() {
        uint8_t buf[8192];
        for (;;) {
            ssize_t n = read(fd_, buf, sizeof(buf));
            if (n > 0) {
                if (onChunk_) {
                    onChunk_(buf, n);
                }
                continue;
            }
            break; // EAGAIN / EOF
        }
    }

    void onReadable() {
        drainPipe(); // EOF 会在 stop 前反复触发，靠 pid 收尸
    }

    EventLoop *loop_ = nullptr;
    ChunkCb onChunk_;
    pid_t pid_ = -1;
    int fd_ = -1;
    std::unique_ptr<EventSourceIO> ev_;
};

} // namespace fcitx

#endif // _FCITX5_VOICEINPUT_AUDIO_CAPTURE_H_
