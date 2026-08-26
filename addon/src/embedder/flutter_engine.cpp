// Flutter 引擎进程内嵌入实现。
//
// 关键坑位：
//  - FlutterEngineRun 配自定义 runner 死锁 → Initialize + RunInitialized
//  - 帧交接单锁快照（尺寸+像素一把锁），否则 resize 动画撕裂
//  - JSONMethodCodec 成功回执是 "[null]"
//  本文件额外约束：所有 FlutterEngine* 调用只在 fcitx5 主线程；present
//  （raster 线程）/ vsync / post_task 回调内绝不调引擎 API，只入队唤醒。
#define _GNU_SOURCE 1
#include "flutter_engine.h"

#include <fcitx-utils/log.h>

#include <pthread.h>
#include <sys/eventfd.h>
#include <unistd.h>

#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>

namespace fcitx {

static constexpr char kChannel[] = "fcitx5/flutterui";
static constexpr int64_t kPrimaryButton = 1; // kFlutterPointerMouseButtonPrimary

// JSONMethodCodec 的方法调用 envelope：{"method":"...","args":...}
static std::string encodeMethodCall(const std::string &method,
                                    const std::string &argsJson) {
    return "{\"method\":\"" + method + "\",\"args\":" + argsJson + "}";
}

// JSON 字符串转义（候选文本走 UTF-8 原样，只处理控制字符）
static std::string jsonEscape(const std::string &s) {
    std::string out;
    out.reserve(s.size() + 8);
    for (unsigned char c : s) {
        switch (c) {
        case '"': out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\n': out += "\\n"; break;
        case '\r': out += "\\r"; break;
        case '\t': out += "\\t"; break;
        default:
            if (c < 0x20) {
                char buf[8];
                snprintf(buf, sizeof(buf), "\\u%04x", c);
                out += buf;
            } else {
                out += static_cast<char>(c);
            }
        }
    }
    return out;
}

FlutterEngineHost::FlutterEngineHost(EventLoop *loop) : loop_(loop) {}

FlutterEngineHost::~FlutterEngineHost() { stop(); }

// —— 跨线程唤醒：eventfd 写端线程安全，读端挂 fcitx 事件循环 ——
bool FlutterEngineHost::addWake(Wake &w, std::function<void()> fn) {
    w.fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    if (w.fd < 0) {
        return false;
    }
    w.src = loop_->addIOEvent(
        w.fd, IOEventFlag::In,
        [fn](EventSourceIO *, int fd, IOEventFlags) {
            uint64_t v;
            while (read(fd, &v, sizeof(v)) > 0) {
            }
            fn();
            return true;
        });
    return w.src != nullptr;
}

void FlutterEngineHost::wake(Wake &w) {
    if (w.fd >= 0) {
        uint64_t one = 1;
        ssize_t r = ::write(w.fd, &one, sizeof(one));
        (void)r;
    }
}

void FlutterEngineHost::closeWake(Wake &w) {
    w.src.reset();
    if (w.fd >= 0) {
        close(w.fd);
        w.fd = -1;
    }
}

bool FlutterEngineHost::start(const std::string &assetsDir,
                              const std::string &icuPath) {
    if (engine_) {
        return true;
    }
    mainThread_ = pthread_self();
    assetsDir_ = assetsDir;
    icuPath_ = icuPath;
    shuttingDown_ = false;

    if (!addWake(taskWake_, [this]() { drainTasks(); }) ||
        !addWake(vsyncWake_, [this]() { deliverVsync(); }) ||
        !addWake(frameWake_, [this]() { commitFrame(); })) {
        FCITX_WARN() << "FlutterEngine: 唤醒通道建立失败";
        closeWake(taskWake_);
        closeWake(vsyncWake_);
        closeWake(frameWake_);
        return false;
    }

    // —— 渲染器：kSoftware，软渲整窗帧 ——
    FlutterRendererConfig renderer = {};
    renderer.type = kSoftware;
    renderer.software.struct_size = sizeof(FlutterSoftwareRendererConfig);
    renderer.software.surface_present_callback =
        [](void *user, const void *allocation, size_t rowBytes,
           size_t height) {
            return FlutterEngineHost::presentCb(user, allocation, rowBytes,
                                                height);
        };

    // —— 自定义 platform task runner：任务全部投回 fcitx5 主循环 ——
    // （栈变量即可：引擎只在 Initialize 期间读取这些指针）
    FlutterTaskRunnerDescription platformRunner = {};
    platformRunner.struct_size = sizeof(FlutterTaskRunnerDescription);
    platformRunner.user_data = this;
    platformRunner.runs_task_on_current_thread_callback =
        [](void *user) {
            return FlutterEngineHost::runsToPlatformThread(user);
        };
    platformRunner.post_task_callback = [](FlutterTask task,
                                           uint64_t target, void *user) {
        FlutterEngineHost::postTaskCb(task, target, user);
    };

    FlutterCustomTaskRunners runners = {};
    runners.struct_size = sizeof(FlutterCustomTaskRunners);
    runners.platform_task_runner = &platformRunner;

    FlutterProjectArgs args = {};
    args.struct_size = sizeof(FlutterProjectArgs);
    args.assets_path = assetsDir_.c_str();
    args.icu_data_path = icuPath_.c_str();
    args.command_line_argc = 0;
    args.command_line_argv = nullptr;
    args.platform_message_callback =
        [](const FlutterPlatformMessage *msg, void *user) {
            FlutterEngineHost::platformMessageCb(msg, user);
        };
    args.vsync_callback = [](void *user, intptr_t baton) {
        FlutterEngineHost::vsyncCb(user, baton);
    };
    args.custom_task_runners = &runners;
    args.log_message_callback =
        [](const char *tag, const char *message, void *user) {
            FlutterEngineHost::logMessageCb(tag, message, user);
        };
    args.log_tag = "flutter-ui";
    // JIT 引擎（官方 embedder 工件只有 linux-x64/JIT）：Dart 侧用
    // kernel_blob（flutter build bundle），不设 AOT snapshot 字段

    FlutterEngineResult r = FlutterEngineInitialize(
        FLUTTER_ENGINE_VERSION, &renderer, &args, this, &engine_);
    if (r != kSuccess || !engine_) {
        FCITX_WARN() << "FlutterEngine: initialize 失败 result=" << (int)r;
        engine_ = nullptr;
        closeWake(taskWake_);
        closeWake(vsyncWake_);
        closeWake(frameWake_);
        return false;
    }
    r = FlutterEngineRunInitialized(engine_); // 坑位 6：不能 FlutterEngineRun
    if (r != kSuccess) {
        FCITX_WARN() << "FlutterEngine: RunInitialized 失败 result=" << (int)r;
        FlutterEngineShutdown(engine_);
        engine_ = nullptr;
        closeWake(taskWake_);
        closeWake(vsyncWake_);
        closeWake(frameWake_);
        return false;
    }

    // 初始窗口尺寸：小占位，Dart 首帧布局后回 resize 消息校正
    updateMetrics(64, 64, 1.0);
    FCITX_INFO() << "FlutterEngine: 引擎已启动（JIT softrender，assets="
                 << assetsDir_ << "）";
    return true;
}

void FlutterEngineHost::stop() {
    if (!engine_) {
        return;
    }
    shuttingDown_ = true;
    // 先关引擎（阻塞至 raster/platform 线程退出），再拆唤醒通道——
    // 反过来会在 Shutdown 期间收到对已销毁 eventfd 的 write()
    FlutterEngineShutdown(engine_);
    engine_ = nullptr;
    closeWake(taskWake_);
    closeWake(vsyncWake_);
    closeWake(frameWake_);
    {
        std::lock_guard<std::mutex> lock(taskMutex_);
        tasks_.clear();
    }
    {
        std::lock_guard<std::mutex> lock(vsyncMutex_);
        batons_.clear();
    }
    FCITX_INFO() << "FlutterEngine: 引擎已停止";
}

// ---------------------------------------------------------------------------
// embedder C 回调（可能不在主线程）
// ---------------------------------------------------------------------------

bool FlutterEngineHost::presentCb(void *user, const void *allocation,
                                  size_t rowBytes, size_t height) {
    auto *self = static_cast<FlutterEngineHost *>(user);
    if (self->shuttingDown_ || !allocation) {
        return true;
    }
    const int w = static_cast<int>(rowBytes / 4);
    const int h = static_cast<int>(height);
    {
        // 单锁快照（坑位 2）：尺寸与像素同锁拷贝，主线程同锁取走
        std::lock_guard<std::mutex> lock(self->frameMutex_);
        const size_t bytes = rowBytes * height;
        self->frameScratch_.resize(bytes);
        memcpy(self->frameScratch_.data(), allocation, bytes);
        self->frameW_ = w;
        self->frameH_ = h;
        self->frameSeq_++;
    }
    wake(self->frameWake_);
    return true;
}

void FlutterEngineHost::vsyncCb(void *user, intptr_t baton) {
    auto *self = static_cast<FlutterEngineHost *>(user);
    if (self->shuttingDown_) {
        return;
    }
    {
        std::lock_guard<std::mutex> lock(self->vsyncMutex_);
        self->batons_.push_back(baton);
    }
    wake(self->vsyncWake_);
}

void FlutterEngineHost::platformMessageCb(const FlutterPlatformMessage *msg,
                                          void *user) {
    auto *self = static_cast<FlutterEngineHost *>(user);
    if (!msg || !msg->message || msg->message_size == 0) {
        return;
    }
    // 只处理本通道；其余（flutter/platform 等引擎内部通道）不响应、
    // 更不能回 JSON envelope——对方多为 Standard 编解码，收到会抛
    // "Message corrupted"
    if (!msg->channel || strcmp(msg->channel, kChannel) != 0) {
        return;
    }
    std::string payload(reinterpret_cast<const char *>(msg->message),
                        msg->message_size);
    // JSONMethodCodec 成功回执 "[null]"（坑位 5）：不回 Dart Future 永挂
    if (msg->response_handle) {
        static const char kOk[] = "[null]";
        FlutterEngineSendPlatformMessageResponse(
            self->engine_, msg->response_handle,
            reinterpret_cast<const uint8_t *>(kOk), sizeof(kOk) - 1);
    }
    self->handleMessage(payload);
}

void FlutterEngineHost::logMessageCb(const char *tag, const char *message,
                                     void *) {
    // Dart print() → 引擎日志（容器内 ui-frame 可观测性走这里）
    FCITX_INFO() << "[" << (tag ? tag : "flutter-ui") << "] "
                 << (message ? message : "");
}

bool FlutterEngineHost::runsToPlatformThread(void *user) {
    auto *self = static_cast<FlutterEngineHost *>(user);
    return pthread_equal(pthread_self(), self->mainThread_) != 0;
}

void FlutterEngineHost::postTaskCb(FlutterTask task, uint64_t, void *user) {
    auto *self = static_cast<FlutterEngineHost *>(user);
    if (self->shuttingDown_) {
        return;
    }
    {
        std::lock_guard<std::mutex> lock(self->taskMutex_);
        self->tasks_.push_back(task);
    }
    wake(self->taskWake_);
}

// ---------------------------------------------------------------------------
// 主循环侧处理
// ---------------------------------------------------------------------------

void FlutterEngineHost::drainTasks() {
    std::deque<FlutterTask> batch;
    {
        std::lock_guard<std::mutex> lock(taskMutex_);
        batch.swap(tasks_);
    }
    for (const auto &t : batch) {
        if (!engine_) {
            break;
        }
        FlutterEngineRunTask(engine_, &t);
    }
}

void FlutterEngineHost::deliverVsync() {
    std::vector<intptr_t> batch;
    {
        std::lock_guard<std::mutex> lock(vsyncMutex_);
        batch.swap(batons_);
    }
    for (intptr_t baton : batch) {
        if (!engine_) {
            break;
        }
        // 16.6ms 帧间隔（本回调签名只给 baton，时间戳自产）
        const uint64_t now =
            static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(
                                      std::chrono::steady_clock::now()
                                          .time_since_epoch())
                                      .count());
        FlutterEngineOnVsync(engine_, baton, now, now + 16666667ull);
    }
}

void FlutterEngineHost::commitFrame() {
    std::vector<uint8_t> pixels;
    int w = 0, h = 0;
    {
        std::lock_guard<std::mutex> lock(frameMutex_);
        if (frameSeq_ == 0) {
            return; // 无新帧（唤醒合并）
        }
        pixels.swap(frameScratch_);
        w = frameW_;
        h = frameH_;
        frameSeq_ = 0;
    }
    if (frameLogCount_ < 3) {
        ++frameLogCount_;
        size_t nz = 0;
        for (size_t i = 0; i < static_cast<size_t>(w) * h; ++i) {
            if (pixels[i * 4] | pixels[i * 4 + 1] | pixels[i * 4 + 2]) {
                ++nz;
            }
        }
        FCITX_INFO() << "FlutterEngine: frame #" << frameLogCount_ << " " << w
                     << "x" << h << " 非零像素=" << nz;
    }
    if (frameCb_ && w > 0 && h > 0) {
        frameCb_(pixels.data(), w, h);
    }
}

// 极简 JSON 字段提取（协议字段全部为本类生成/约定的扁平对象，不引 JSON 库）
static bool jsonFindNumber(const std::string &s, const char *key,
                           double *out) {
    std::string pat = "\"" + std::string(key) + "\":";
    auto pos = s.find(pat);
    if (pos == std::string::npos) {
        return false;
    }
    *out = strtod(s.c_str() + pos + pat.size(), nullptr);
    return true;
}

void FlutterEngineHost::handleMessage(const std::string &payload) {
    // {"method":"xxx","args":{...}}
    auto mpos = payload.find("\"method\":\"");
    if (mpos == std::string::npos) {
        return;
    }
    size_t start = mpos + 10; // "\"method\":\"" 本身长度
    auto mend = payload.find('"', start);
    if (mend == std::string::npos) {
        return;
    }
    std::string method = payload.substr(start, mend - start);
    std::string args;
    auto apos = payload.find("\"args\":");
    if (apos != std::string::npos) {
        auto objStart = payload.find('{', apos);
        auto objEnd = payload.rfind('}');
        if (objStart != std::string::npos && objEnd != std::string::npos &&
            objEnd > objStart) {
            args = payload.substr(objStart, objEnd - objStart + 1);
        }
    }

    if (method == "resize") {
        double w = 0, h = 0;
        if (jsonFindNumber(args, "w", &w) && jsonFindNumber(args, "h", &h) &&
            w > 0 && h > 0 && resizeHandler_) {
            resizeHandler_(static_cast<int>(w), static_cast<int>(h));
        }
    } else if (handler_) {
        handler_(method, args);
    }
}

// ---------------------------------------------------------------------------
// 输入 / 输出（主线程）
// ---------------------------------------------------------------------------

void FlutterEngineHost::updateMetrics(double width, double height,
                                      double pixelRatio) {
    if (!engine_) {
        return;
    }
    FlutterWindowMetricsEvent metrics = {};
    metrics.struct_size = sizeof(FlutterWindowMetricsEvent);
    metrics.width = width;   // 物理像素 = 逻辑 × ratio
    metrics.height = height; //
    metrics.pixel_ratio = pixelRatio;
    lastRatio_ = pixelRatio;
    FlutterEngineSendWindowMetricsEvent(engine_, &metrics);
}

void FlutterEngineHost::sendMethod(const std::string &method,
                                  const std::string &argsJson) {
    if (!engine_) {
        return;
    }
    std::string payload = encodeMethodCall(method, argsJson);
    FlutterPlatformMessage msg = {};
    msg.struct_size = sizeof(FlutterPlatformMessage);
    msg.channel = kChannel;
    msg.message = reinterpret_cast<const uint8_t *>(payload.data());
    msg.message_size = payload.size();
    msg.response_handle = nullptr;
    FlutterEngineSendPlatformMessage(engine_, &msg);
}

void FlutterEngineHost::onPointer(PointerKind kind, double x, double y) {
    if (!engine_) {
        return;
    }
    // embedder 约定 FlutterPointerEvent.x/y 是物理像素（与 metrics 同一
    // 空间），引擎内部再 ÷dpr 还原逻辑做命中。调用方给的是表面局部
    // 逻辑坐标——不乘这一下，命中位置会被缩到左上 1/scale：副屏
    // 「指针在第二行、高亮在第一行」与卡片下方红区仍能悬停的根因
    auto send = [this](FlutterPointerPhase phase, double px, double py,
                       int64_t buttons) {
        FlutterPointerEvent ev = {};
        ev.struct_size = sizeof(FlutterPointerEvent);
        ev.phase = phase;
        ev.timestamp =
            static_cast<size_t>(std::chrono::duration_cast<std::chrono::microseconds>(
                                    std::chrono::steady_clock::now()
                                        .time_since_epoch())
                                    .count());
        ev.x = px * lastRatio_;
        ev.y = py * lastRatio_;
        ev.device = 0;
        ev.signal_kind = kFlutterPointerSignalKindNone;
        ev.device_kind = kFlutterPointerDeviceKindMouse;
        ev.buttons = buttons;
        FlutterEngineSendPointerEvent(engine_, &ev, 1);
    };
    switch (kind) {
    case PointerKind::Enter:
        if (!ptrAdded_) {
            ptrAdded_ = true;
            send(kAdd, x, y, 0);
        }
        // Enter 不补发 kHover：Enter 常是「表面在静止指针下方弹出」，
        // 合成 hover 会立即抢走方向键选择；真实移动走 Motion 的 kHover
        if (ptrDown_) {
            send(kMove, x, y, kPrimaryButton);
        }
        break;
    case PointerKind::Leave:
        if (ptrAdded_) {
            send(kRemove, x, y, 0);
            ptrAdded_ = false;
        }
        break;
    case PointerKind::Motion:
        if (ptrAdded_) {
            send(ptrDown_ ? kMove : kHover, x, y,
                 ptrDown_ ? kPrimaryButton : 0);
        }
        break;
    case PointerKind::Press:
        if (!ptrAdded_) { // 没 enter 就按下：补 Add
            ptrAdded_ = true;
            send(kAdd, x, y, 0);
        }
        ptrDown_ = true;
        send(kDown, x, y, kPrimaryButton);
        break;
    case PointerKind::Release:
        if (ptrAdded_) {
            ptrDown_ = false;
            send(kUp, x, y, 0);
        }
        break;
    }
}

// 供 aiinput.cpp 组 update JSON（导出 jsonEscape 语义）
std::string flutterJsonEscape(const std::string &s) { return jsonEscape(s); }

} // namespace fcitx
