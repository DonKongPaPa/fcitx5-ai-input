#ifndef _FCITX5_AIINPUT_HUB_UI_BUS_H_
#define _FCITX5_AIINPUT_HUB_UI_BUS_H_

#include <functional>
#include <string>
#include <vector>

#include "flutter_engine.h" // flutterJsonEscape（embedder 层工具）

namespace fcitx {

// ui 通道发射器（协议 v1，lab/spec/protocol.md）：只负责事件组包与发送，
// 会话决策留在 core。传输无关：sender 注入——进程内为 Flutter 引擎的
// platform channel，未来可换 stdio/socket；测试可注 mock 收集。
//
// wire：MethodCall(method, args) 直上 'fcitx5/flutterui' 通道，method 即
// v1 事件名（voice/recording 等）。Dart 侧 _onTransportMessage 原生解析。
class UiBus {
public:
    using Sender = std::function<void(const std::string &method,
                                      const std::string &argsJson)>;

    void setSender(Sender sender) { sender_ = std::move(sender); }
    bool ready() const { return static_cast<bool>(sender_); }

    void theme(const std::string &fontPath, double size, double anim);
    void voiceRecording(const std::string &partial, uint64_t elapsedMs,
                        double anim);
    void voiceResult(const std::string &finalText, int timeoutMs,
                     double anim);
    void voiceCandidates(const std::string &finalText,
                         const std::vector<std::string> &candidates,
                         int hover, bool llmDummy, double anim);
    void voiceIdle(double anim);
    void panelUpdate(const std::string &preeditJson,
                     const std::string &auxUp, const std::string &auxDown,
                     const std::string &candidatesJson, int cursor,
                     const std::string &layout, bool hasPrev, bool hasNext,
                     int page, const std::string &imName);
    void panelHide();

private:
    void send(const std::string &method, const std::string &args) {
        if (sender_) {
            sender_(method, args);
        }
    }
    Sender sender_;
};

} // namespace fcitx

#endif // _FCITX5_AIINPUT_HUB_UI_BUS_H_
