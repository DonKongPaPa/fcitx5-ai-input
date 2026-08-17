#ifndef _FCITX5_VOICEINPUT_UI_BRIDGE_H_
#define _FCITX5_VOICEINPUT_UI_BRIDGE_H_

#include <fcitx-utils/event.h>
#include <fcitx/instance.h>

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace fcitx {

class VoicePopup;

/**
 * Flutter UI 桥。
 *
 * 职责：按需拉起 flutter UI 进程（跑在专用无头合成器上）→ TCP 监听
 * 127.0.0.1 → 接收行式 JSON + RGBA 帧二进制 → VoicePopup::pushFrame。
 * 状态机变化时向 flutter 推送 state 消息（JSON 行）。
 *
 * 协议见 flutter/lib/main.dart 头注释。所有 IO 都挂在 fcitx 主事件循环
 * （addIOEvent），无额外线程；帧回调在主线程直达 popup。
 */
class UiBridge {
public:
    UiBridge(Instance *instance, VoicePopup *popup);
    ~UiBridge();

    // 惰性启动：popup 首次 show 时调用。返回 flutter 进程是否拉起成功
    bool ensureStarted();
    // 状态推送（未连接时丢弃；flutter 重连后由下次状态变化驱动重绘）
    void sendState(const std::string &line);
    // 组装并发送 recording 状态（含计时）
    void sendRecording(const std::string &partial, uint64_t elapsedMs);
    void sendResult(const std::string &finalText, int timeoutMs);
    void sendCandidates(const std::string &finalText,
                        const std::vector<std::string> &candidates);
    void sendIdle();

    bool connected() const { return clientFd_ >= 0; }
    bool processAlive() const;

private:
    bool startListener(); // TCP listen 127.0.0.1:0
    bool spawnUi();       // fork/exec flutter bundle
    void onAcceptable();
    void onReadable();
    void closeClient();
    void parseBuffer(std::vector<uint8_t> &buf);

    Instance *instance_;
    VoicePopup *popup_;

    int listenFd_ = -1;
    int clientFd_ = -1;
    std::unique_ptr<EventSourceIO> listenEvent_;
    std::unique_ptr<EventSourceIO> clientEvent_;
    std::vector<uint8_t> rbuf_;

    int childPid_ = -1;
    int port_ = -1;
    bool spawnFailed_ = false; // 二进制缺失等：不再反复 fork
};

} // namespace fcitx

#endif // _FCITX5_VOICEINPUT_UI_BRIDGE_H_
