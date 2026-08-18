#ifndef _FCITX5_VOICEINPUT_FUNASR_LOCAL_ENGINE_H_
#define _FCITX5_VOICEINPUT_FUNASR_LOCAL_ENGINE_H_

#include "asr_engine.h"
#include "audio_capture.h"

#include <fcitx-utils/event.h>

#include <string>
#include <vector>

namespace fcitx {

/**
 * FunASR 本地档（GGUF / llama-funasr-cli 子进程）：
 * 非流式——录音期只采集（波形+计时的 UI 形态），stop 时落盘 wav →
 * llama-funasr-cli 识别（CPU，~1.5GB RSS，zh/en/ja）→ stdout 末行=文本。
 *
 * 全程挂 fcitx 主事件循环：CLI 通过 pipe + IOEvent 读取，超时 30s 兜底。
 */
class FunAsrLocalEngine : public AsrEngine {
public:
    bool streamingCapable() const override { return false; }
    void start(EventLoop *loop, const VoiceInputConfig *config,
               Callbacks cbs) override;
    void stop() override;    // 落盘 → 起 CLI → onFinish
    void cancel() override;  // 杀采集/CLI，丢弃

private:
    void runCli();
    void onCliReadable();
    void onCliDone();
    void finishSession(const std::string &text);
    void teardownAll();

    EventLoop *loop_ = nullptr;
    const VoiceInputConfig *config_ = nullptr;
    Callbacks cbs_;
    bool finished_ = false;

    std::unique_ptr<AudioCapture> capture_;
    std::vector<uint8_t> pcm_; // s16le/16k/mono 全量
    std::string wavPath_;

    pid_t cliPid_ = -1;
    int cliFd_ = -1; // stdout pipe
    std::unique_ptr<EventSourceIO> cliEv_;
    std::unique_ptr<EventSourceTime> cliTimer_;
    std::string cliOut_;
};

} // namespace fcitx

#endif // _FCITX5_VOICEINPUT_FUNASR_LOCAL_ENGINE_H_
