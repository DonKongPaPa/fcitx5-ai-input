#define _GNU_SOURCE 1
#include "funasr_local_engine.h"

#include "audio_capture.h"
#include "aiinput_config.h"

#include <fcitx-utils/log.h>

#include <fcntl.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cstring>

namespace fcitx {

static constexpr int kCliTimeoutSec = 30;

static uint64_t nowUs() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<uint64_t>(ts.tv_sec) * 1000000 + ts.tv_nsec / 1000;
}

void FunAsrLocalEngine::start(EventLoop *loop, const AiInputConfig *config,
                              Callbacks cbs) {
    loop_ = loop;
    config_ = config;
    cbs_ = std::move(cbs);
    finished_ = false;
    pcm_.clear();

    capture_ = std::make_unique<AudioCapture>();
    if (!capture_->start(loop_, [this](const uint8_t *d, size_t n) {
            pcm_.insert(pcm_.end(), d, d + n);
        })) {
        FCITX_WARN() << "FunAsrLocal: parec 启动失败";
        finishSession("");
    }
}

void FunAsrLocalEngine::stop() {
    if (finished_) {
        return;
    }
    if (capture_) {
        capture_->stop();
    }
    if (pcm_.empty()) {
        finishSession("");
        return;
    }
    runCli();
}

// 最小 WAV 头（PCM s16le/16k/mono）
static void writeWav(const std::string &path,
                     const std::vector<uint8_t> &pcm) {
    uint32_t dataLen = pcm.size();
    uint32_t byteRate = 16000 * 2;
    uint32_t blockAlign = 2;
    FILE *f = fopen(path.c_str(), "wb");
    if (!f) {
        return;
    }
    auto w32 = [&](uint32_t v) { fwrite(&v, 4, 1, f); };
    auto w16 = [&](uint16_t v) { fwrite(&v, 2, 1, f); };
    fwrite("RIFF", 1, 4, f);
    w32(36 + dataLen);
    fwrite("WAVEfmt ", 1, 8, f);
    w32(16);      // fmt chunk size
    w16(1);       // PCM
    w16(1);       // mono
    w32(16000);   // rate
    w32(byteRate);
    w16(blockAlign);
    w16(16);      // bits
    fwrite("data", 1, 4, f);
    w32(dataLen);
    fwrite(pcm.data(), 1, dataLen, f);
    fclose(f);
}

void FunAsrLocalEngine::runCli() {
    wavPath_ = "/tmp/aiinput-session.wav";
    writeWav(wavPath_, pcm_);

    const std::string dir = config_->funasrLocalModelDir.value();
    const std::string quant = config_->funasrLocalQuant.value();
    std::string llm = "qwen3-0.6b-" + quant + ".gguf";
    // 兼容旧命名 q4km → q4_K_M 由用户配置保证；此处直接拼接

    int fds[2];
    if (pipe(fds) != 0) {
        finishSession("");
        return;
    }
    cliPid_ = fork();
    if (cliPid_ == 0) {
        ::close(fds[0]);
        dup2(fds[1], 1);
        int devnull = open("/dev/null", O_WRONLY);
        if (devnull >= 0) {
            dup2(devnull, 2);
        }
        // tiktoken 按相对路径解析：cwd 切到模型目录
        if (chdir(dir.c_str()) != 0) {
            _exit(126);
        }
        const std::string enc = dir + "/funasr-encoder-f16.gguf";
        const std::string llmPath = dir + "/" + llm;
        const std::string vad = dir + "/fsmn-vad.gguf";
        char *const argv[] = {
            const_cast<char *>(config_->funasrLocalCmd.value().c_str()),
            const_cast<char *>("--enc"),   const_cast<char *>(enc.c_str()),
            const_cast<char *>("-m"),      const_cast<char *>(llmPath.c_str()),
            const_cast<char *>("-a"),      const_cast<char *>(wavPath_.c_str()),
            const_cast<char *>("--vad"),   const_cast<char *>(vad.c_str()),
            nullptr,
        };
        execv(argv[0], argv);
        _exit(127);
    }
    ::close(fds[1]);
    if (cliPid_ < 0) {
        ::close(fds[0]);
        finishSession("");
        return;
    }
    cliFd_ = fds[0];
    int flags = fcntl(cliFd_, F_GETFL);
    fcntl(cliFd_, F_SETFL, flags | O_NONBLOCK);
    cliOut_.clear();
    cliEv_ = loop_->addIOEvent(
        cliFd_, IOEventFlag::In,
        [this](EventSourceIO *, int, IOEventFlags) {
            onCliReadable();
            return true;
        });
    cliTimer_ = loop_->addTimeEvent(
        CLOCK_MONOTONIC, nowUs() + kCliTimeoutSec * 1000000ULL, 0,
        [this](EventSourceTime *, uint64_t) {
            FCITX_WARN() << "FunAsrLocal: CLI 超时";
            if (cliPid_ > 0) {
                kill(cliPid_, SIGKILL);
            }
            onCliDone();
            return false;
        });
    FCITX_INFO() << "FunAsrLocal: CLI 识别中 (" << pcm_.size() / 32000.0
                 << "s 音频)";
}

void FunAsrLocalEngine::onCliReadable() {
    char buf[4096];
    for (;;) {
        ssize_t n = read(cliFd_, buf, sizeof(buf));
        if (n > 0) {
            cliOut_.append(buf, n);
            continue;
        }
        if (n == 0) {
            onCliDone();
            return;
        }
        if (errno == EINTR) {
            continue;
        }
        return; // EAGAIN
    }
}

void FunAsrLocalEngine::onCliDone() {
    if (cliPid_ > 0) {
        int st = 0;
        // 等待退出（CLI 结束才关 stdout，此时必已退出或即将；带 WNOHANG 轮询
        // 一次足够，EOF 先于 exit 的情况由 timer 兜底）
        if (waitpid(cliPid_, &st, WNOHANG) == 0) {
            usleep(50000); // 50ms，本地进程收尾
            waitpid(cliPid_, &st, WNOHANG);
        }
        cliPid_ = -1;
    }
    cliEv_.reset();
    cliTimer_.reset();
    if (cliFd_ >= 0) {
        ::close(cliFd_);
        cliFd_ = -1;
    }
    // 文本 = stdout 末个非空行（CLI 的进度/日志混在其中）
    std::string last;
    size_t pos = 0;
    while (pos < cliOut_.size()) {
        size_t e = cliOut_.find('\n', pos);
        std::string line = cliOut_.substr(
            pos, (e == std::string::npos ? cliOut_.size() : e) - pos);
        // 剥离 \r 与 ANSI 般的 [tag] 行
        while (!line.empty() && (line.back() == '\r' || line.back() == ' ')) {
            line.pop_back();
        }
        if (!line.empty() && line[0] != '[') {
            last = line;
        }
        if (e == std::string::npos) {
            break;
        }
        pos = e + 1;
    }
    finishSession(last);
}

void FunAsrLocalEngine::cancel() {
    finished_ = true;
    if (cliPid_ > 0) {
        kill(cliPid_, SIGKILL);
        waitpid(cliPid_, nullptr, WNOHANG);
        cliPid_ = -1;
    }
    teardownAll();
}

void FunAsrLocalEngine::finishSession(const std::string &text) {
    if (finished_) {
        return;
    }
    finished_ = true;
    teardownAll();
    if (cbs_.onFinish) {
        cbs_.onFinish(text);
    }
}

void FunAsrLocalEngine::teardownAll() {
    cliEv_.reset();
    cliTimer_.reset();
    if (capture_) {
        capture_->stop();
        capture_.reset();
    }
    if (cliFd_ >= 0) {
        ::close(cliFd_);
        cliFd_ = -1;
    }
}

} // namespace fcitx
