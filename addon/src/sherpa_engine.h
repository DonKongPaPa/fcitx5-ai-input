#ifndef _FCITX5_VOICEINPUT_SHERPA_ENGINE_H_
#define _FCITX5_VOICEINPUT_SHERPA_ENGINE_H_

#include "asr_engine.h"

#include <chrono>
#include <string>
#include <vector>

namespace fcitx {

// 模型目录解析（voiceinput.cpp 健康检查共用）
std::string resolveSherpaModelDir(const VoiceInputConfig *config);
std::string findModelFile(const std::string &dir, const char *prefix, bool preferInt8);

/**
 * sherpa-onnx CPU 流式引擎。
 *
 * 进程内直链 libsherpa-onnx-c-api.so（v1.13.6），双语流式 paraformer
 * int8 模型：RSS 412MB / 首字 0.069s / RTF 0.04 / 0 显存常驻。
 * 输出无标点——由 polish()/LLM 润色候选兜底补句号。
 *
 * 音频路径与 FunAsrWs 相同：parec(s16le) → 主循环回调内攒窗 →
 * AcceptWaveform（float）→ while(IsReady)Decode → GetResult → onPartial。
 * 每 100ms 窗解码 ~4ms（int8/4 线程），主循环可承受。
 * stop()：InputFinished → 收尾 decode → onFinish；模型缺失时
 * onFinish("")（与 FunASR 服务不可用同语义）。
 */
class SherpaOnnxEngine : public AsrEngine {
public:
    bool streamingCapable() const override { return true; }

    void start(EventLoop *loop, const VoiceInputConfig *config,
               Callbacks cbs) override;
    void stop() override;
    void cancel() override;

private:
    void finishSession(const std::string &text);
    void teardownAll();
    void initOfflineRecognizer(const VoiceInputConfig *config);

    EventLoop *loop_ = nullptr;
    const VoiceInputConfig *config_ = nullptr;
    Callbacks cbs_;
    bool finished_ = false;

    std::unique_ptr<class AudioCapture> capture_;
    // sherpa C API 不透明句柄
    void *recognizer_ = nullptr; // 进程级缓存（见 cpp，不随会话销毁）
    void *stream_ = nullptr;
    std::vector<float> pending_; // s16→float 攒 ~100ms（1600 样本）
    std::string lastPartial_;
    bool firstChunk_ = true; // 首块延迟诊断（漏字定位）
    std::chrono::steady_clock::time_point startedAt_;

    // —— SenseVoice 松手重识别 ——
    // 流式 partial 的最终质量受流式模型上限约束（混说/标点/尾音），
    // stop() 时对整段会话缓冲离线重识别出 final。
    void *offlineRec_ = nullptr; // 进程级缓存（同 recognizer_ 纪律）
    std::vector<float> sessionAudio_; // 会话全量音频（含尾部宽限）
};

} // namespace fcitx

#endif // _FCITX5_VOICEINPUT_SHERPA_ENGINE_H_
