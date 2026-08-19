// sherpa-onnx CPU 流式引擎实现（实验 004 结论产品化，详见 sherpa_engine.h）
#include "sherpa_engine.h"

#include "audio_capture.h"

#include <fcitx-utils/log.h>

#include "sherpa-onnx/c-api.h"

#include <chrono>
#include <cstdlib>
#include <cstring>

namespace fcitx {

// 模型目录解析：config 覆盖 → env → 用户默认 → 系统共享路径
static std::string resolveModelDir(const VoiceInputConfig *config) {
    const auto &cfgDir = config->sherpaModelDir.value();
    if (!cfgDir.empty()) {
        return cfgDir;
    }
    if (const char *env = getenv("VOICEINPUT_SHERPA_MODEL_DIR"); env && *env) {
        return env;
    }
    if (const char *home = getenv("HOME"); home && *home) {
        return std::string(home) +
               "/.local/share/fcitx5-voiceinput/models/sherpa-paraformer";
    }
    return "/usr/share/fcitx5-voiceinput/models/sherpa-paraformer";
}

void SherpaOnnxEngine::start(EventLoop *loop, const VoiceInputConfig *config,
                             Callbacks cbs) {
    loop_ = loop;
    config_ = config;
    cbs_ = std::move(cbs);
    finished_ = false;

    const std::string dir = resolveModelDir(config);
    const std::string encoder = dir + "/encoder.int8.onnx";
    const std::string decoder = dir + "/decoder.int8.onnx";
    const std::string tokens = dir + "/tokens.txt";
    if (access(encoder.c_str(), R_OK) != 0 ||
        access(decoder.c_str(), R_OK) != 0 ||
        access(tokens.c_str(), R_OK) != 0) {
        FCITX_WARN() << "Sherpa: 模型缺失 " << dir
                     << "（scripts/fetch-sherpa-models.sh 下载，或 "
                        "configtool 配置模型目录）";
        finishSession("");
        return;
    }

    // —— 配置（对齐实验 004 的 python 参数：16k/80 维/4 线程/cpu）——
    SherpaOnnxOnlineRecognizerConfig c = {};
    c.feat_config.sample_rate = 16000;
    c.feat_config.feature_dim = 80;
    c.model_config.paraformer.encoder = encoder.c_str();
    c.model_config.paraformer.decoder = decoder.c_str();
    c.model_config.tokens = tokens.c_str();
    c.model_config.num_threads = config->sherpaNumThreads.value();
    c.model_config.provider = "cpu";
    c.model_config.debug = 0;
    c.decoding_method = "greedy_search";
    c.enable_endpoint = 0; // 按键控录音：不需要 VAD 断句

    const auto t0 = std::chrono::steady_clock::now();
    recognizer_ = const_cast<SherpaOnnxOnlineRecognizer *>(
        SherpaOnnxCreateOnlineRecognizer(&c));
    if (!recognizer_) {
        FCITX_WARN() << "Sherpa: 创建 recognizer 失败（模型损坏？）";
        finishSession("");
        return;
    }
    stream_ = const_cast<SherpaOnnxOnlineStream *>(
        SherpaOnnxCreateOnlineStream(
            static_cast<SherpaOnnxOnlineRecognizer *>(recognizer_)));
    if (!stream_) {
        FCITX_WARN() << "Sherpa: 创建 stream 失败";
        teardownAll();
        finishSession("");
        return;
    }
    const auto loadMs = std::chrono::duration_cast<std::chrono::milliseconds>(
                            std::chrono::steady_clock::now() - t0)
                            .count();
    FCITX_INFO() << "Sherpa: 模型就绪（加载 " << loadMs << "ms，threads="
                 << config->sherpaNumThreads.value() << "）";

    capture_ = std::make_unique<AudioCapture>();
    if (!capture_->start(loop_, [this](const uint8_t *d, size_t n) {
            // s16le → float，攒 ~100ms（1600 样本）喂一窗（比实验的 0.6s
            // 窗更细——partial 出字更快，解码开销同量级）
            const auto *s16 = reinterpret_cast<const int16_t *>(d);
            const size_t samples = n / 2;
            for (size_t i = 0; i < samples; ++i) {
                pending_.push_back(static_cast<float>(s16[i]) / 32768.0f);
            }
            if (pending_.size() < 1600) {
                return;
            }
            SherpaOnnxOnlineStreamAcceptWaveform(
                static_cast<SherpaOnnxOnlineStream *>(stream_), 16000,
                pending_.data(), static_cast<int32_t>(pending_.size()));
            pending_.clear();
            auto *rec = static_cast<SherpaOnnxOnlineRecognizer *>(recognizer_);
            auto *st = static_cast<SherpaOnnxOnlineStream *>(stream_);
            while (SherpaOnnxIsOnlineStreamReady(rec, st)) {
                SherpaOnnxDecodeOnlineStream(rec, st);
            }
            const auto *r = SherpaOnnxGetOnlineStreamResult(rec, st);
            if (r && r->text && r->text != lastPartial_) {
                lastPartial_ = r->text;
                cbs_.onPartial(lastPartial_);
            }
            if (r) {
                SherpaOnnxDestroyOnlineRecognizerResult(
                    const_cast<SherpaOnnxOnlineRecognizerResult *>(r));
            }
        })) {
        FCITX_WARN() << "Sherpa: parec 启动失败";
        teardownAll();
        finishSession("");
    }
}

void SherpaOnnxEngine::stop() {
    if (finished_) {
        return;
    }
    capture_.reset();
    if (!stream_) { // start 失败路径已 finishSession 过
        return;
    }
    auto *rec = static_cast<SherpaOnnxOnlineRecognizer *>(recognizer_);
    auto *st = static_cast<SherpaOnnxOnlineStream *>(stream_);
    // 尾部音频 flush
    if (!pending_.empty()) {
        SherpaOnnxOnlineStreamAcceptWaveform(st, 16000, pending_.data(),
                                             static_cast<int32_t>(pending_.size()));
        pending_.clear();
    }
    SherpaOnnxOnlineStreamInputFinished(st);
    while (SherpaOnnxIsOnlineStreamReady(rec, st)) {
        SherpaOnnxDecodeOnlineStream(rec, st);
    }
    const auto *r = SherpaOnnxGetOnlineStreamResult(rec, st);
    std::string text = r && r->text ? r->text : lastPartial_;
    if (r) {
        SherpaOnnxDestroyOnlineRecognizerResult(
            const_cast<SherpaOnnxOnlineRecognizerResult *>(r));
    }
    teardownAll();
    finishSession(text);
}

void SherpaOnnxEngine::cancel() {
    capture_.reset();
    teardownAll();
    finished_ = true;
}

void SherpaOnnxEngine::finishSession(const std::string &text) {
    finished_ = true;
    if (cbs_.onFinish) {
        cbs_.onFinish(text);
    }
}

void SherpaOnnxEngine::teardownAll() {
    if (stream_) {
        SherpaOnnxDestroyOnlineStream(
            static_cast<SherpaOnnxOnlineStream *>(stream_));
        stream_ = nullptr;
    }
    if (recognizer_) {
        SherpaOnnxDestroyOnlineRecognizer(
            static_cast<SherpaOnnxOnlineRecognizer *>(recognizer_));
        recognizer_ = nullptr;
    }
    pending_.clear();
    lastPartial_.clear();
}

} // namespace fcitx
