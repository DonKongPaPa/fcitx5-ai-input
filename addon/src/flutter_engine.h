#ifndef _FCITX5_VOICEINPUT_FLUTTER_ENGINE_H_
#define _FCITX5_VOICEINPUT_FLUTTER_ENGINE_H_

#include <fcitx-utils/event.h>

#include "flutter_embedder.h"

#include <atomic>
#include <cstdint>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace fcitx {

/**
 * Flutter 引擎进程内嵌入（v1 实现报告 §6 路线）。
 *
 * raw embedder API + kSoftware 软渲染：引擎把整窗 RGBA 帧经
 * surface_present_callback 交出（raster 线程）→ 单锁快照 → async 唤醒主
 * 线程 → 写入 VoicePopup 的 wl_shm。不需要 GTK 窗口 / weston / 独立进程。
 *
 * 线程模型（报告 §6.2/§13）：
 *  - platform 任务由自定义 task runner 投回 fcitx5 主循环执行（Dart 的
 *    MethodChannel 消息才能在主线程到达）；配自定义 runner 时必须
 *    Initialize + RunInitialized（FlutterEngineRun 死锁）
 *  - present 回调在 raster 线程：只拷贝 + 唤醒，绝不碰 wayland
 *  - vsync 回调只挂 baton，主循环统一回 FlutterEngineOnVsync（回调内调
 *    引擎 API 是重入）
 *  - 引擎 API 只在主线程调用
 *
 * 消息协议（channel "fcitx5/flutterui"，JSONMethodCodec，wire 为
 * {"method":"...","args":...} UTF-8 JSON）：
 *  - C++→Dart : update{state,partial,elapsed_ms,final,timeout_ms,candidates}
 *  - Dart→C++ : ready / resize{w,h} / selectCandidate{index} / hoverChanged{row}
 */
class FlutterEngineHost {
public:
    // popup_surface 转发的指针事件（表面局部坐标，含 kShadowPad 余量）
    enum class PointerKind { Enter, Leave, Motion, Press, Release };

    // 主线程帧回调：bgra 已预乘、wl_shm ARGB8888 小端字节序，可直接 memcpy
    using FrameCallback = std::function<void(const uint8_t *bgra, int w, int h)>;
    using MessageHandler =
        std::function<void(const std::string &method, const std::string &args)>;

    explicit FlutterEngineHost(EventLoop *loop);
    ~FlutterEngineHost();

    // JIT 引擎：assetsDir 指向含 kernel_blob.bin 的 flutter_assets 目录
    bool start(const std::string &assetsDir, const std::string &icuPath);
    void stop();
    bool running() const { return engine_ != nullptr; }

    void setFrameCallback(FrameCallback cb) { frameCb_ = std::move(cb); }
    void setMessageHandler(MessageHandler h) { handler_ = std::move(h); }
    // Dart resize 消息（逻辑尺寸）——交给使用方统筹（popup 池 + metrics scale）
    void setResizeHandler(std::function<void(int, int)> h) {
        resizeHandler_ = std::move(h);
    }

    // C++→Dart 状态推送（argsJson 为 update 的 JSON 对象体）
    void sendUpdate(const std::string &argsJson);

    // 窗口尺寸（逻辑像素；pixelRatio 当前固定 1.0——popup 池即逻辑尺寸）
    void updateMetrics(double width, double height, double pixelRatio);

    // popup_surface 指针事件入口（内部合成 Add/Remove/Hover/Down/Move/Up）
    void onPointer(PointerKind kind, double x, double y);

private:
    // embedder C 回调（静态，user_data=this）
    static bool presentCb(void *user, const void *allocation, size_t rowBytes,
                          size_t height);
    static void vsyncCb(void *user, intptr_t baton);
    static void platformMessageCb(const FlutterPlatformMessage *msg,
                                  void *user);
    static void logMessageCb(const char *tag, const char *message, void *user);
    static bool runsToPlatformThread(void *user);
    static void postTaskCb(FlutterTask task, uint64_t targetTimeNanos,
                           void *user);

    // 主循环侧处理
    void drainTasks();
    void deliverVsync();
    void commitFrame();
    void handleMessage(const std::string &payload);

    EventLoop *loop_;
    FlutterEngine engine_ = nullptr;
    std::string assetsDir_, icuPath_;
    pthread_t mainThread_{};

    // —— 跨线程唤醒（eventfd + addIOEvent；addAsyncEvent 是 5.1.13+ API，
    // bookworm 5.0 没有）——
    struct Wake {
        int fd = -1;
        std::unique_ptr<EventSourceIO> src;
    };
    bool addWake(Wake &w, std::function<void()> fn);
    static void wake(Wake &w);
    void closeWake(Wake &w);

    Wake taskWake_;  // platform 任务队列非空
    Wake vsyncWake_; // vsync baton 待回
    Wake frameWake_; // raster 帧就绪

    // platform 任务队列：post_task（引擎线程）→ 队列 + 唤醒 → 主循环逐个
    // FlutterEngineRunTask
    std::mutex taskMutex_;
    std::deque<FlutterTask> tasks_;

    // vsync baton 队列（回调内不能直接 OnVsync）
    std::mutex vsyncMutex_;
    std::vector<intptr_t> batons_;

    // 帧交接：raster 线程写 scratch，主线程单锁快照（报告 §6.3：两把锁分
    // 别取尺寸/像素会撕裂）
    std::mutex frameMutex_;
    std::vector<uint8_t> frameScratch_;
    int frameW_ = 0, frameH_ = 0;
    uint64_t frameSeq_ = 0; // scratch 版本号；主线程消费后清零表示可覆盖
    int frameLogCount_ = 0; // 前 3 帧记日志（对应旧 ui-frame 可观测性）

    // 指针状态（Flutter 需要 Add 在前 / Remove 后不再发）
    bool ptrAdded_ = false;
    bool ptrDown_ = false;

    FrameCallback frameCb_;
    MessageHandler handler_;
    std::function<void(int, int)> resizeHandler_;
    std::atomic<bool> shuttingDown_{false};
};

// JSON 字符串转义（voiceinput.cpp 组 update 消息用）
std::string flutterJsonEscape(const std::string &s);

} // namespace fcitx

#endif // _FCITX5_VOICEINPUT_FLUTTER_ENGINE_H_
