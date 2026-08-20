// sherpa-onnx CPU 流式引擎实现（详见 sherpa_engine.h）
#include "sherpa_engine.h"

#include "audio_capture.h"

#include <fcitx-utils/log.h>

#include "sherpa-onnx/c-api.h"

#include <chrono>
#include <cstdlib>
#include <dirent.h>
#include <cstring>

namespace fcitx {

// 模型目录解析：config 覆盖 → env → 用户默认 → 系统共享路径
// 目录内按前缀找模型文件：preferInt8 时优先 *.int8.onnx，否则任意 .onnx。
// zipformer 的文件名带 epoch（encoder-epoch-99-avg-1.onnx），通配匹配
std::string findModelFile(const std::string &dir, const char *prefix,
                          bool preferInt8) {
    DIR *d = opendir(dir.c_str());
    if (!d) {
        return "";
    }
    std::string best, bestInt8;
    struct dirent *e;
    while ((e = readdir(d)) != nullptr) {
        std::string n = e->d_name;
        if (n.size() < 5 || n.substr(n.size() - 5) != ".onnx" ||
            n.rfind(prefix, 0) != 0) {
            continue;
        }
        if (n.find(".int8.onnx") != std::string::npos) {
            if (bestInt8.empty() || n < bestInt8) {
                bestInt8 = n;
            }
        } else if (best.empty() || n < best) {
            best = n;
        }
    }
    closedir(d);
    if (preferInt8 && !bestInt8.empty()) {
        return dir + "/" + bestInt8;
    }
    if (!best.empty()) {
        return dir + "/" + best;
    }
    return !bestInt8.empty() ? dir + "/" + bestInt8 : "";
}

std::string resolveSherpaModelDir(const VoiceInputConfig *config) {
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

void SherpaOnnxEngine::initOfflineRecognizer(const VoiceInputConfig *config) {
    const std::string dir = config->senseVoiceDir.value();
    // 进程级缓存（与流式 recognizer 同纪律）：键 = 目录；失败不缓存
    static SherpaOnnxOfflineRecognizer *cachedOff = nullptr;
    static std::string cachedOffDir;
    static bool cachedOffFailed = false;
    offlineRec_ = nullptr;
    if (dir.empty()) {
        return;
    }
    if (cachedOffFailed && cachedOffDir == dir) {
        return; // 上次已失败，别每会话重试 1s 加载
    }
    if (!cachedOff || cachedOffDir != dir) {
        const std::string model = dir + "/model.int8.onnx";
        const std::string tokens = dir + "/tokens.txt";
        if (access(model.c_str(), R_OK) != 0 ||
            access(tokens.c_str(), R_OK) != 0) {
            FCITX_WARN() << "SenseVoice: 模型缺失 " << dir
                         << "（scripts/fetch-sherpa-models.sh --model "
                            "sensevoice 下载；清空 SenseVoiceDir 可关闭）";
            cachedOffFailed = true;
            cachedOffDir = dir;
            return;
        }
        SherpaOnnxOfflineRecognizerConfig c;
        memset(&c, 0, sizeof c);
        // 路径字符串存活到 Create 结束（c_str() 悬垂 = config 错误，踩过）
        c.model_config.sense_voice.model = model.c_str();
        c.model_config.sense_voice.language = "auto";
        c.model_config.sense_voice.use_itn = 1;
        c.model_config.tokens = tokens.c_str();
        c.model_config.num_threads = config->sherpaNumThreads.value();
        c.model_config.provider = "cpu";
        const auto t0 = std::chrono::steady_clock::now();
        cachedOff = const_cast<SherpaOnnxOfflineRecognizer *>(
            SherpaOnnxCreateOfflineRecognizer(&c));
        cachedOffDir = dir;
        cachedOffFailed = cachedOff == nullptr;
        if (cachedOff) {
            FCITX_INFO() << "SenseVoice: 离线 final 模型就绪（加载 "
                         << std::chrono::duration_cast<
                                std::chrono::milliseconds>(
                                std::chrono::steady_clock::now() - t0)
                                .count()
                         << "ms）";
        } else {
            FCITX_WARN() << "SenseVoice: 创建 recognizer 失败（模型损坏？）";
        }
    }
    offlineRec_ = cachedOff;
}

void SherpaOnnxEngine::start(EventLoop *loop, const VoiceInputConfig *config,
                             Callbacks cbs) {
    loop_ = loop;
    config_ = config;
    cbs_ = std::move(cbs);
    finished_ = false;

    const std::string dir = resolveSherpaModelDir(config);
    const std::string tokens = dir + "/tokens.txt";
    // 双架构探测（与下方加载严格同源，勿各自为政——检查与加载各写
    // 一套会误报模型缺失）：
    //   zipformer：joiner*/encoder*/decoder*.onnx（epoch 命名，通配匹配）
    //   paraformer：encoder.int8.onnx + decoder.int8.onnx（固定命名）
    std::string joiner = findModelFile(dir, "joiner", false); // fp32 优先
    std::string zfEnc = findModelFile(dir, "encoder", false); // fp32 优先
    std::string zfDec = findModelFile(dir, "decoder", false); // fp32 优先
    // zipformer 的 decoder/joiner 必须 fp32：int8 量化的 joiner 在 greedy/
    // beam 下都会 token 复读（吞掉真实尾词）；fp32 decoder/joiner 仅比
    // int8 大 ~10MB，encoder 量化与否不影响。旧目录只有 int8 时
    // findModelFile 兜底可用
    const std::string encoder = dir + "/encoder.int8.onnx";
    const std::string decoder = dir + "/decoder.int8.onnx";
    const bool isZipformer =
        !joiner.empty() && !zfEnc.empty() && !zfDec.empty();
    const bool isParaformer =
        access(encoder.c_str(), R_OK) == 0 && access(decoder.c_str(), R_OK) == 0;
    if (access(tokens.c_str(), R_OK) != 0 || (!isZipformer && !isParaformer)) {
        FCITX_WARN() << "Sherpa: 模型缺失 " << dir
                     << "（scripts/fetch-sherpa-models.sh 下载，或 "
                        "configtool 配置模型目录）";
        finishSession("");
        return;
    }

    // —— 采集先于一切模型加载启动 ——
    // 模型加载（流式首载 ~1.3s / SenseVoice ~0.9s）会阻塞主循环，若排在
    // 采集前，parec 晚起 + 管道溢出 = 整段开头丢失。采集先起，加载期间
    // 音频缓冲在管道（已扩 1MB≈30s）；onChunk 回调在主循环上，start()
    // 返回前不可能触发，stream_ 届时已就绪
    firstChunk_ = true;
    startedAt_ = std::chrono::steady_clock::now();
    sessionAudio_.clear();
    sessionAudio_.reserve(16000 * 30); // 预留 30s
    capture_ = std::make_unique<AudioCapture>();
    if (!capture_->start(loop_, [this](const uint8_t *d, size_t n) {
            if (firstChunk_) {
                firstChunk_ = false;
                FCITX_INFO() << "Sherpa: 首块音频到达（begin 后 "
                             << std::chrono::duration_cast<
                                    std::chrono::milliseconds>(
                                    std::chrono::steady_clock::now() -
                                    startedAt_)
                                    .count()
                             << "ms；含模型加载阻塞，期间音频缓冲于管道"
                               "不丢失——数值大但识别完整即正常）";
            }
            // s16le → float，攒 ~100ms（1600 样本）喂一窗（partial 出字
            // 快，解码开销同量级）
            const auto *s16 = reinterpret_cast<const int16_t *>(d);
            const size_t samples = n / 2;
            for (size_t i = 0; i < samples; ++i) {
                const float f = static_cast<float>(s16[i]) / 32768.0f;
                pending_.push_back(f);
                // 会话全量缓冲（SenseVoice 松手重识别用），2 分钟封顶
                if (sessionAudio_.size() < 16000 * 120) {
                    sessionAudio_.push_back(f);
                }
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
        finishSession("");
        return;
    }

    // —— 流式 recognizer（音频已在管道里缓冲）——
    // —— 配置：16k / 80 维 / cpu ——
    SherpaOnnxOnlineRecognizerConfig c = {};
    c.feat_config.sample_rate = 16000;
    c.feat_config.feature_dim = 80;
    if (isZipformer) {
        c.model_config.transducer.encoder = zfEnc.c_str();
        c.model_config.transducer.decoder = zfDec.c_str();
        c.model_config.transducer.joiner = joiner.c_str();
        FCITX_INFO() << "Sherpa: zipformer transducer（双语混说档）";
    } else {
        c.model_config.paraformer.encoder = encoder.c_str();
        c.model_config.paraformer.decoder = decoder.c_str();
    }
    c.model_config.tokens = tokens.c_str();
    c.model_config.num_threads = config->sherpaNumThreads.value();
    c.model_config.provider = "cpu";
    c.model_config.debug = 0;
    // 解码 greedy：复读根因是 int8 decoder/joiner（fp32 化已根除）；
    // beam 在 addon 内流式哑火（勿换），greedy+fp32 已无复读且最快
    c.decoding_method = "greedy_search";
    c.enable_endpoint = 0; // 按键控录音：不需要 VAD 断句

    const auto t0 = std::chrono::steady_clock::now();
    // recognizer 常驻缓存：模型加载 ~0.9s，若每会话新建会在按键瞬间
    // 阻塞主循环（grab 下全部键盘输入冻结）。进程级单例，stream 才是
    // 会话级。缓存键含模型目录与线程数：configtool 换目录
    //（zipformer↔paraformer 对比）需重建，否则旧架构 recognizer 被
    // 静默复用；换键时销毁旧实例并同步更新 static 指针
    static SherpaOnnxOnlineRecognizer *cachedRec = nullptr;
    static std::string cachedDir;
    static int cachedThreads = 0;
    if (!cachedRec || cachedThreads != c.model_config.num_threads ||
        cachedDir != dir) {
        if (cachedRec) {
            SherpaOnnxDestroyOnlineRecognizer(cachedRec);
            FCITX_INFO() << "Sherpa: 模型目录/线程变化，重建 recognizer";
        }
        cachedRec = const_cast<SherpaOnnxOnlineRecognizer *>(
            SherpaOnnxCreateOnlineRecognizer(&c));
        cachedDir = dir;
        cachedThreads = c.model_config.num_threads;
    }
    recognizer_ = cachedRec;
    if (!recognizer_) {
        FCITX_WARN() << "Sherpa: 创建 recognizer 失败（模型损坏？）";
        capture_.reset();
        finishSession("");
        return;
    }
    stream_ = const_cast<SherpaOnnxOnlineStream *>(
        SherpaOnnxCreateOnlineStream(
            static_cast<SherpaOnnxOnlineRecognizer *>(recognizer_)));
    if (!stream_) {
        FCITX_WARN() << "Sherpa: 创建 stream 失败";
        capture_.reset();
        teardownAll();
        finishSession("");
        return;
    }
    const auto loadMs = std::chrono::duration_cast<std::chrono::milliseconds>(
                            std::chrono::steady_clock::now() - t0)
                            .count();
    FCITX_INFO() << "Sherpa: 模型就绪（加载 " << loadMs << "ms，threads="
                 << config->sherpaNumThreads.value() << "）";

    // SenseVoice 离线 final 模型（采集已就绪，加载期音频在管道缓冲中）
    initOfflineRecognizer(config);
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
    // teardownAll 会清 lastPartial_，先记下本会话流式是否出过字
    // （全程无字 + 离线极短 = 对房间噪声的幻觉，如误触按键时的「我.」）
    const bool hadPartial = !lastPartial_.empty() || !text.empty();
    if (r) {
        SherpaOnnxDestroyOnlineRecognizerResult(
            const_cast<SherpaOnnxOnlineRecognizerResult *>(r));
    }
    teardownAll();
    // SenseVoice 整段重识别（配置了目录才启用）：混说/标点/尾音完整度
    // 显著优于流式 final，失败/空结果回落流式文本
    if (offlineRec_ && sessionAudio_.size() >= 1600) {
        const auto t1 = std::chrono::steady_clock::now();
        auto *ost = SherpaOnnxCreateOfflineStream(
            static_cast<SherpaOnnxOfflineRecognizer *>(offlineRec_));
        if (ost) {
            SherpaOnnxAcceptWaveformOffline(
                ost, 16000, sessionAudio_.data(),
                static_cast<int32_t>(sessionAudio_.size()));
            SherpaOnnxDecodeOfflineStream(
                static_cast<SherpaOnnxOfflineRecognizer *>(offlineRec_), ost);
            const auto *orr = SherpaOnnxGetOfflineStreamResult(ost);
            std::string sv = orr && orr->text ? orr->text : "";
            if (orr) {
                SherpaOnnxDestroyOfflineRecognizerResult(
                    const_cast<SherpaOnnxOfflineRecognizerResult *>(orr));
            }
            SherpaOnnxDestroyOfflineStream(
                const_cast<SherpaOnnxOfflineStream *>(ost));
            const auto ms = std::chrono::duration_cast<
                                std::chrono::milliseconds>(
                                std::chrono::steady_clock::now() - t1)
                                .count();
            sessionAudio_.clear();
            if (!sv.empty() && !hadPartial && sv.size() <= 3) {
                FCITX_INFO() << "Sherpa: SenseVoice final（" << ms
                             << "ms）流式全程无输出，丢弃噪声幻觉「" << sv
                             << "」";
            } else if (!sv.empty()) {
                FCITX_INFO() << "Sherpa: SenseVoice final（" << ms
                             << "ms）流式「" << text << "」→ 离线「" << sv
                             << "」";
                text = sv;
            } else {
                FCITX_INFO() << "Sherpa: SenseVoice final 空（" << ms
                             << "ms），回落流式结果";
            }
        }
    }
    finishSession(text);
}

void SherpaOnnxEngine::cancel() {
    capture_.reset();
    teardownAll();
    sessionAudio_.clear();
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
    // 缓存的 recognizer 永不随会话销毁：跨会话复用是它的使命；进程退出
    // 由 OS 统一回收（会话 teardown 销毁会让 static 指针悬垂——第二段
    // 语音 CreateOnlineStream 直接 SEGV）
    recognizer_ = nullptr;
    pending_.clear();
    lastPartial_.clear();
}

} // namespace fcitx
