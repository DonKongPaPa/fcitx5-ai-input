#ifndef _FCITX5_VOICEINPUT_FUNASR_WS_ENGINE_H_
#define _FCITX5_VOICEINPUT_FUNASR_WS_ENGINE_H_

#include "asr_engine.h"
#include "audio_capture.h"

#include <fcitx-utils/event.h>

#include <cstdint>
#include <string>
#include <vector>

namespace fcitx {

/**
 * FunASR 流式引擎（WS 档）：宿主 funasr-serve（实验 001 的 MLT 模型 +
 * 累积窗口流式，31 语种，GPU/CPU）。
 *
 * 链路：parec 采集 → 手写 WS 客户端（HTTP Upgrade + 帧编解码，零外部
 * 依赖）→ 二进制 PCM 分片上行；服务端回 JSON {"text","is_final"}。
 * 协议见 scripts/funasr-server/server.py 头注释。
 *
 * stop(): 发 is_speaking=false，等 final（10s 超时兜底）。
 * cancel(): 直接断开，不回调。
 */
class FunAsrWsEngine : public AsrEngine {
public:
    bool streamingCapable() const override { return true; }
    void start(EventLoop *loop, const VoiceInputConfig *config,
               Callbacks cbs) override;
    void stop() override;    // 正常收尾 → onFinish
    void cancel() override;  // 全部丢弃

private:
    bool connectServer(const std::string &host, int port);
    bool wsHandshake();
    bool sendWsFrame(bool text, const uint8_t *payload, size_t len);
    bool sendText(const std::string &s) {
        return sendWsFrame(true, reinterpret_cast<const uint8_t *>(s.data()),
                           s.size());
    }
    void onSocketReadable();
    void feedRecvBuffer(uint8_t *data, size_t len);
    void handleTextMessage(const std::string &msg);
    void finishSession(const std::string &text);
    void teardownAll();
    void scheduleFinalTimeout();

    EventLoop *loop_ = nullptr;
    const VoiceInputConfig *config_ = nullptr;
    Callbacks cbs_;
    bool finished_ = false;

    std::unique_ptr<AudioCapture> capture_;
    int sockFd_ = -1;
    std::unique_ptr<EventSourceIO> sockEv_;
    std::vector<uint8_t> recvBuf_; // WS 帧重组缓冲
    std::vector<uint8_t> frame_;   // 当前帧累积
    bool gotFinal_ = false;
    bool stopSent_ = false; // is_speaking=false 已送达
    std::unique_ptr<EventSourceTime> finalTimer_;
    std::unique_ptr<EventSourceTime> stopRetryTimer_;
    std::unique_ptr<EventSource> stopDefer_;
    uint64_t chunkAccum_ = 0; // 攒 ~100ms 再发一帧
    std::vector<uint8_t> pending_;
    int dropCount_ = 0;       // 音频块丢弃计数（节流日志用）

    void scheduleStopRetry();
};

} // namespace fcitx

#endif // _FCITX5_VOICEINPUT_FUNASR_WS_ENGINE_H_
