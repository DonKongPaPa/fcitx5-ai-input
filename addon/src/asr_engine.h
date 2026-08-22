#ifndef _FCITX5_AIINPUT_ASR_ENGINE_H_
#define _FCITX5_AIINPUT_ASR_ENGINE_H_

#include "aiinput_config.h"

#include <fcitx-utils/event.h>

#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace fcitx {

/**
 * ASR 引擎抽象（流式/非流式统一）。
 * 回调在 addon 所在的 fcitx5 主事件循环线程上执行（Dummy 用 EventLoop 定时器，
 * 真实引擎接自己的解码线程后 post 回主循环）。
 *
 * 流式：start 后可持续回调 onPartial（中间文本，全量式）；
 *       stop 触发一次 onFinish（最终文本）。
 * 非流式：start 后无 partial，stop（或引擎自行完成）时 onFinish。
 */
class AsrEngine {
public:
    struct Callbacks {
        std::function<void(const std::string &)> onPartial;
        std::function<void(const std::string &)> onFinish;
        std::function<void()> onCancel;
    };
    virtual ~AsrEngine() = default;
    virtual bool streamingCapable() const = 0;
    virtual void start(EventLoop *loop, const AiInputConfig *config,
                       Callbacks cbs) = 0;
    virtual void stop() = 0;
    // 取消会话：不触发 onFinish/onCancel 之外的收尾副作用
    //（stop 的语义是"正常收尾出最终文本"，cancel 是"全部丢弃"）
    virtual void cancel() { stop(); }
};

/** 调试用 Dummy 引擎：完全跳过音频，按配置逐字/延迟吐出固定文本。 */
class DummyAsrEngine : public AsrEngine {
public:
    bool streamingCapable() const override { return true; }

    void start(EventLoop *loop, const AiInputConfig *config,
               Callbacks cbs) override {
        loop_ = loop;
        cbs_ = std::move(cbs);
        config_ = config;
        finished_ = false;
        pos_ = 0;

        // 轮换文本
        auto texts = splitTexts(config->dummyText.value());
        counter_ = (counter_ + 1) % texts.size();
        text_ = texts[counter_];

        if (config->dummyStream.value() && config->streamingEnabled.value()) {
            pos_ = 0;
            scheduleNext();
        }
        // 非流式：stop() 时一次性给全文；这里不设完成定时器（延迟由 stop 侧
        // 语义覆盖），保持"说话时长=用户控制"的真实交互
    }

    void stop() override {
        if (streamTimer_) {
            streamTimer_.reset();
        }
        deferNext_.reset();
        if (finished_) {
            return;
        }
        finished_ = true;
        if (cbs_.onFinish) {
            cbs_.onFinish(text_);
        }
    }

    void cancel() override {
        // 丢弃一切：定时器停掉、不再回调（onFinish/onPartial 都不出）
        if (streamTimer_) {
            streamTimer_.reset();
        }
        deferNext_.reset();
        finished_ = true;
    }

private:
    static std::vector<std::string> splitTexts(const std::string &joined) {
        std::vector<std::string> out;
        std::string cur;
        for (size_t i = 0; i < joined.size(); ++i) {
            char c = joined[i];
            bool sep = false;
            if (c == ';') {
                sep = true;
            } else if (static_cast<unsigned char>(c) == 0xEF &&
                       i + 2 < joined.size() &&
                       static_cast<unsigned char>(joined[i + 1]) == 0xBC &&
                       static_cast<unsigned char>(joined[i + 2]) == 0x9B) {
                sep = true; // 全角分号 U+FF1B（3 字节，不能与 char 直接比较）
                i += 2;
            }
            if (sep) {
                if (!cur.empty()) {
                    out.push_back(cur);
                }
                cur.clear();
            } else {
                cur += c;
            }
        }
        if (!cur.empty()) {
            out.push_back(cur);
        }
        if (out.empty()) {
            out.push_back("dummy");
        }
        return out;
    }

    static uint64_t nowUs() {
        struct timespec ts;
        clock_gettime(CLOCK_MONOTONIC, &ts);
        return static_cast<uint64_t>(ts.tv_sec) * 1000000 + ts.tv_nsec / 1000;
    }

    // 在 defer 回调中安全替换 timer（不在其自身分发栈内析构）
    // 注意 defer 源必须保存，否则 unique_ptr 立即析构回调永不执行
    std::unique_ptr<EventSource> deferNext_;
    void scheduleNext() {
        streamTimer_ = loop_->addTimeEvent(
            CLOCK_MONOTONIC,
            nowUs() + config_->dummyStreamIntervalMs.value() * 1000, 0,
            [this](EventSourceTime *, uint64_t) {
                emitNext();
                return true;
            });
    }

    // 逐字（UTF-8 安全：按前导字节推下一个字符边界）
    void emitNext() {
        if (pos_ >= text_.size()) {
            return; // 等待 stop() 收尾
        }
        if (pos_ + 1 < text_.size()) {
            // 时间事件严格一次性：经 defer 事件链调度下一字（回调内直接
            // reset 自身源会破坏分发，defer 后已脱离其栈）
            deferNext_ = loop_->addDeferEvent([this](EventSource *) {
                if (!finished_) {
                    scheduleNext();
                }
                return true;
            });
        }
        size_t next = pos_ + 1;
        while (next < text_.size() &&
               (static_cast<uint8_t>(text_[next]) & 0xC0) == 0x80) {
            ++next;
        }
        pos_ = next;
        if (cbs_.onPartial) {
            cbs_.onPartial(text_.substr(0, pos_));
        }
    }

    EventLoop *loop_ = nullptr;
    const AiInputConfig *config_ = nullptr;
    Callbacks cbs_;
    std::string text_;
    size_t pos_ = 0;
    size_t counter_ = 0;
    bool finished_ = false;
    std::unique_ptr<EventSourceTime> streamTimer_;
};

} // namespace fcitx

#endif // _FCITX5_AIINPUT_ASR_ENGINE_H_
