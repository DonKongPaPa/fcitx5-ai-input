#ifndef _FCITX5_AIINPUT_STDIO_ASR_ENGINE_H_
#define _FCITX5_AIINPUT_STDIO_ASR_ENGINE_H_

#include "../hub/stdio_backend.h"
#include "asr_engine.h"

#include <fcitx-utils/event.h>

#include <memory>
#include <string>

namespace fcitx {

/**
 * v1 协议进程外 ASR 引擎（P6 解耦试验田）：
 * 子进程收发 envelope 行协议（lab/spec/protocol.md asr 通道事件表）。
 * hello/asr/start → asr/partial* → asr/stop → asr/final。
 *
 * 音频不进后端命令行——dummy 脚本无音频；真实 ASR 后端自行经
 * PulseAudio/pipewire 抓取（asr/start.args.cfg 带会话参数）。
 */
class StdioAsrEngine : public AsrEngine {
public:
    bool streamingCapable() const override { return true; }

    void start(EventLoop *loop, const AiInputConfig *config,
               Callbacks cbs) override;
    void stop() override;
    void cancel() override;

private:
    void onLine(const std::string &line);
    // stop 后限时等待 asr/final；超时视为后端卡死，用最后 partial 收尾
    void armStopFallback();

    StdioBackend backend_;
    EventLoop *loop_ = nullptr;
    Callbacks cbs_;
    std::string lastPartial_;
    bool finished_ = false;
    std::unique_ptr<EventSourceTime> stopFallback_;
};

} // namespace fcitx

#endif // _FCITX5_AIINPUT_STDIO_ASR_ENGINE_H_
