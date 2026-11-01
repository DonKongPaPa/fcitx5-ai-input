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

    SocketUi(Instance *instance, const std::string &sockPath,
             const std::string &spawnCmd, LineHandler onLine);
    ~SocketUi();

    // 镜像发送一条 ui 通道事件（dir=out）；无客户端连接时静默丢弃
    void sendEnvelope(const std::string &method, const std::string &argsJson);

private:
    void acceptClient();
    void handleClientRead();
    void detachClient();

    Instance *instance_;
    std::string sockPath_;
    LineHandler onLine_;
    int serverFd_ = -1;
    int clientFd_ = -1;
    std::unique_ptr<EventSourceIO> serverWatch_;
    std::unique_ptr<EventSourceIO> clientWatch_;
    std::string buf_;
    pid_t spawnPid_ = -1;
};

} // namespace fcitx

#endif // _FCITX5_AIINPUT_UI_SOCKET_UI_H_
