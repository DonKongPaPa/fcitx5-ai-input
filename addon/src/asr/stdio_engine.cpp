#include "stdio_engine.h"

#include "../core/aiinput_config.h"
#include "../hub/proto_line.h"

#include <fcitx-utils/log.h>

namespace fcitx {

static uint64_t nowUs() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<uint64_t>(ts.tv_sec) * 1000000 + ts.tv_nsec / 1000;
}

void StdioAsrEngine::start(EventLoop *loop, const AiInputConfig *config,
                           Callbacks cbs) {
    loop_ = loop;
    cbs_ = std::move(cbs);
    lastPartial_.clear();
    finished_ = false;
    stopFallback_.reset();

    const auto &cmd = config->stdioAsrCmd.value();
    bool ok = backend_.spawn(
        loop, cmd,
        [this](const std::string &line) { onLine(line); },
        [this]() {
            // EOF：后端退出。已出 final 则正常；否则用最后 partial 收尾
            //（后端崩溃不能卡死会话状态机）
            if (!finished_) {
                finished_ = true;
                FCITX_WARN() << "AiInput: [asr-stdio] 后端意外退出，"
                             << "以最后 partial 收尾";
                if (cbs_.onFinish) {
                    cbs_.onFinish(lastPartial_);
                }
            }
        });
    if (!ok) {
        finished_ = true;
        if (cbs_.onFinish) {
            cbs_.onFinish("");
        }
        return;
    }
    bool streaming = config->streamingEnabled.value();
    backend_.send("{\"v\":1,\"channel\":\"asr\",\"dir\":\"out\","
                  "\"method\":\"hello\",\"seq\":1,"
                  "\"args\":{\"proto\":1,\"caps\":[]}}");
    std::string start =
        "{\"v\":1,\"channel\":\"asr\",\"dir\":\"out\","
        "\"method\":\"asr/start\",\"seq\":2,\"args\":{\"cfg\":{"
        "\"engine\":\"stdio\"},\"streaming\":" +
        std::string(streaming ? "true" : "false") + "}}";
    backend_.send(start);
    FCITX_LOG(Info) << "AiInput: [asr-stdio] 会话已启动 streaming="
                    << streaming;
}

void StdioAsrEngine::onLine(const std::string &line) {
    auto method = envelopeMethod(line);
    if (method == "asr/partial") {
        lastPartial_ = jsonStrField(line, "text");
        if (!finished_ && cbs_.onPartial) {
            cbs_.onPartial(lastPartial_);
        }
        return;
    }
    if (method == "asr/final") {
        if (finished_) {
            return;
        }
        finished_ = true;
        stopFallback_.reset();
        auto text = jsonStrField(line, "text");
        FCITX_LOG(Info) << "AiInput: [asr-stdio] final 到达";
        if (cbs_.onFinish) {
            cbs_.onFinish(text);
        }
        backend_.terminate();
        return;
    }
    // asr/cancelled / hello / 未知 method：忽略（向前兼容语义）
}

void StdioAsrEngine::armStopFallback() {
    stopFallback_ = loop_->addTimeEvent(
        CLOCK_MONOTONIC, nowUs() + 3000000, 0,
        [this](EventSourceTime *, uint64_t) {
            if (!finished_) {
                finished_ = true;
                FCITX_WARN() << "AiInput: [asr-stdio] asr/final 3s 未到，"
                             << "后端终止，以最后 partial 收尾";
                backend_.terminate();
                if (cbs_.onFinish) {
                    cbs_.onFinish(lastPartial_);
                }
            }
            return false;
        });
    if (stopFallback_) {
        stopFallback_->setOneShot();
    }
}

void StdioAsrEngine::stop() {
    if (finished_) {
        return;
    }
    // 正常收尾语义：后端应回 asr/final；3s 未回按崩溃处理
    if (!backend_.send("{\"v\":1,\"channel\":\"asr\",\"dir\":\"out\","
                       "\"method\":\"asr/stop\",\"seq\":3,\"args\":{}}")) {
        finished_ = true;
        if (cbs_.onFinish) {
            cbs_.onFinish(lastPartial_);
        }
        return;
    }
    armStopFallback();
}

void StdioAsrEngine::cancel() {
    finished_ = true;
    stopFallback_.reset();
    backend_.send("{\"v\":1,\"channel\":\"asr\",\"dir\":\"out\","
                  "\"method\":\"asr/cancel\",\"seq\":4,\"args\":{}}");
    backend_.terminate();
}

} // namespace fcitx
