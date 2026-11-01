#ifndef _FCITX5_AIINPUT_UI_SOCKET_UI_H_
#define _FCITX5_AIINPUT_UI_SOCKET_UI_H_

#include <fcitx-utils/event.h>
#include <fcitx/instance.h>

#include <functional>
#include <memory>
#include <string>

namespace fcitx {

/**
 * QML 卡片传输（M2，Unix socket）：aiinput-ui 是**服务端**，Quickshell 卡
 * 是客户端（探针结论：Quickshell.Io 无读自身 stdin 的类型，socket 是唯一
 * 进程外通道；卡片断线自动重连，连上即发 ready）。
 *
 * wire：每行一个完整 v1 envelope（{"v":1,"channel":"ui","dir":"out",
 * "method":...,"args":{...}}，紧凑 JSON + '\n'）——与 stdio 回放同封套，
 * 与 Flutter platform channel 的 {method,args} 薄封装不同。
 *
 * 单客户端语义：新连接顶掉旧连接（对比期只有一张 QML 卡）。
 * 卡片回写（dir=in）按行回调使用方；resize 是卡片自身布局语义，由使用
 * 方决定不回流引擎。
 */
class SocketUi {
public:
    // 卡片回写（method + args 对象体 JSON）
    using LineHandler =
        std::function<void(const std::string &method, const std::string &args)>;
    // QML 卡渲染帧（frame-relay，lab/spec/frame-relay.md）：宽高 + PPM
    // 字节流（P6，RGB），由使用方转 BGRA 上屏
    using FrameHandler =
        std::function<void(int w, int h, const uint8_t *rgb, size_t len)>;

    SocketUi(Instance *instance, const std::string &sockPath,
             const std::string &spawnCmd, LineHandler onLine,
             FrameHandler onFrame);
    ~SocketUi();

    // 镜像发送一条 ui 通道事件（dir=out）；无客户端连接时静默丢弃
    void sendEnvelope(const std::string &method, const std::string &argsJson);

private:
    void acceptClient();
    void acceptFrameClient();
    void handleClientRead();
    void handleFrameRead();
    void detachClient();
    void detachFrameClient();
    // FRM 帧头后累积的 payload 按帧回调（P6 解析在使用方；本类只切帧）
    void feedFrame(const uint8_t *data, size_t len);

    Instance *instance_;
    std::string sockPath_;
    LineHandler onLine_;
    FrameHandler onFrame_;
    int serverFd_ = -1;
    int clientFd_ = -1;
    // 帧通道：第二 socket（aiinput-frame.sock），纯二进制与行协议互不阻塞
    std::string framePath_;
    int frameServerFd_ = -1;
    int frameFd_ = -1;
    std::unique_ptr<EventSourceIO> serverWatch_;
    std::unique_ptr<EventSourceIO> clientWatch_;
    std::unique_ptr<EventSourceIO> frameServerWatch_;
    std::unique_ptr<EventSourceIO> frameWatch_;
    std::string buf_;
    std::string frameBuf_;   // FRM 头 + payload 的重组缓冲
    size_t frameExpect_ = 0; // 当前帧 payload 期望长度（0=等头）
    pid_t spawnPid_ = -1;
};

} // namespace fcitx

#endif // _FCITX5_AIINPUT_UI_SOCKET_UI_H_
