#ifndef _FCITX5_VOICEINPUT_CONFIG_H_
#define _FCITX5_VOICEINPUT_CONFIG_H_

#include <fcitx-config/configuration.h>
#include <fcitx-config/enum.h>
#include <fcitx-config/option.h>
#include <fcitx-utils/i18n.h>
#include <fcitx-utils/key.h>

namespace fcitx {

// 触发模式：HoldRelease=按住说话，松开结束；
//           Toggle=长按阈值后持续录音，再次按下触发键结束
FCITX_CONFIG_ENUM(TriggerMode, HoldRelease, Toggle);
FCITX_CONFIG_ENUM_I18N_ANNOTATION(TriggerMode, "HoldRelease", "Toggle");

// ASR 引擎：Dummy=调试用模拟输出（默认）；
//           FunASR=流式 WS 档（宿主 funasr-serve，MLT 31 语种，GPU/CPU）；
//           FunASRLocal=GGUF 本地档（llama-funasr-cli 子进程，zh/en/ja，
//           非流式，CPU ~1.5GB 内存）
FCITX_CONFIG_ENUM(AsrEngineKind, Dummy, FunASR, FunASRLocal, Sherpa);
FCITX_CONFIG_ENUM_I18N_ANNOTATION(AsrEngineKind, "Dummy", "FunASR",
                                  "FunASRLocal", "Sherpa");

// 模型部署设备档（自动拉起服务时的参数）
FCITX_CONFIG_ENUM(FunASRDeviceKind, Auto, Gpu, Cpu);
FCITX_CONFIG_ENUM_I18N_ANNOTATION(FunASRDeviceKind, "Auto", "Gpu", "Cpu");

// 量化档（CPU 提速；GPU 无收益）
FCITX_CONFIG_ENUM(FunASRQuantKind, None, Int8);
FCITX_CONFIG_ENUM_I18N_ANNOTATION(FunASRQuantKind, "None", "Int8");

// configtool 由该 Configuration 自动生成设置页；保存后经 D-Bus 触发
// reloadConfig()，参数即时生效（无需重启 fcitx5）
FCITX_CONFIGURATION(
    VoiceInputConfig,

    // —— 组1 触发 ——
    Option<KeyList> triggerKeys{
        this, "TriggerKeys", "触发键（可多条，支持组合，默认右Ctrl）",
        KeyList{Key("Control_R")}};
    Option<TriggerMode, NoConstrain<TriggerMode>, DefaultMarshaller<TriggerMode>, TriggerModeI18NAnnotation> triggerMode{
        this, "TriggerMode", "触发模式（HoldRelease=按住说话松开结束，"
                             "Toggle=长按后持续录音再按结束）",
        TriggerMode::HoldRelease};
    Option<int> triggerThresholdMs{
        this, "TriggerThresholdMs", "长按阈值（毫秒，建议 50-2000，超过才触发录音）",
        300};

    // —— 组2 语音引擎 ——
    // —— Sherpa CPU 流式引擎（RSS ~412MB/首字 ~0.07s/0 显存）——
    Option<std::string> sherpaModelDir{
        this, "SherpaModelDir",
        "Sherpa 模型目录（含 encoder.int8.onnx/decoder.int8.onnx/tokens.txt；"
        "留空 = ~/.local/share/fcitx5-voiceinput/models/sherpa-paraformer，"
        "下载见 scripts/fetch-sherpa-models.sh）",
        ""};
    Option<int> sherpaNumThreads{
        this, "SherpaNumThreads", "Sherpa 解码线程数", 4};
    // 松手后用 SenseVoice 离线模型对整段重识别出 final（流式 partial 仍由
    // 上面的流式模型驱动）。SenseVoice 对中英混说/标点/结尾完整度都显著
    // 更好；留空 = 关闭，final 回落到流式结果
    Option<std::string> senseVoiceDir{
        this, "SenseVoiceDir",
        "SenseVoice 离线模型目录（含 model.int8.onnx/tokens.txt，松手后整段"
        "重识别提升中英混说与标点；留空 = 关闭；下载 scripts/fetch-sherpa-models.sh --model sensevoice）",
        ""};

    // —— UI 字体 ——
    Option<std::string> uiFont{
        this, "UIFont",
        "悬浮卡片字体（Pango 格式如 \"MiSans VF 13\"；留空 = 跟随 classicui 的字体设置）",
        ""};

    // —— 卡片定位 ——
    // chromium 系只在文本/光标变化时上报 text-input 光标矩形（焦点时不
    // 报）。auto：收到过真实矩形（GTK/Qt）或本 IC 上屏过
    // （上屏即有新鲜矩形可继承，chromium 也跟随）→ 跟随光标；否则（处女
    // 字段）layer-shell 底部居中。caret：强制跟随。top/bottom：全部
    // 顶部/底部居中
    Option<std::string> positionMode{
        this, "PositionMode",
        "卡片定位模式（auto=可跟随则跟随（含 chromium 上屏后继承），否则底部居中 / caret=强制跟随光标 / bottom=全部底部居中 / top=全部顶部居中）",
        "auto"};
    Option<std::string> positionFallbackApps{
        this, "PositionFallbackApps",
        "强制底部居中的应用列表（逗号分隔，匹配程序名/app-id 子串；留空=自动判断——默认自动）",
        ""};

    Option<AsrEngineKind, NoConstrain<AsrEngineKind>, DefaultMarshaller<AsrEngineKind>, AsrEngineKindI18NAnnotation> asrEngine{
        this, "AsrEngine", "ASR 引擎（Dummy=调试模拟，FunASR=流式识别，"
                           "FunASRLocal=本地轻量档 zh/en/ja 非流式）",
        AsrEngineKind::Dummy};
    Option<bool> streamingEnabled{
        this, "StreamingEnabled", "流式识别（实时显示中间结果，引擎支持时）",
        true};
    Option<bool> llmEnabled{
        this, "LLMEnabled", "LLM 优化输出（开启时结果先入候选框）", true};

    // —— 组2.1 FunASR 流式（WS 档）——
    Option<std::string> funasrUrl{
        this, "FunASRUrl", "FunASR 流式服务地址（ws://host:port）",
        "ws://127.0.0.1:10095"};
    Option<std::string> funasrLanguage{
        this, "FunASRLanguage", "识别语言（中文/英文/日文…，MLT 31 语种）",
        "中文"};

    // —— 组2.1.1 模型部署（服务自动拉起；产品=宿主原生进程）——
    Option<bool> funasrAutoStart{
        this, "FunASRAutoStart",
        "自动启动识别服务（连接失败且未运行时按下方设备/量化档拉起）",
        false};
    Option<FunASRDeviceKind, NoConstrain<FunASRDeviceKind>, DefaultMarshaller<FunASRDeviceKind>, FunASRDeviceKindI18NAnnotation> funasrDevice{
        this, "FunASRDevice", "部署设备（自动/优先GPU/CPU）",
        FunASRDeviceKind::Auto};
    Option<FunASRQuantKind, NoConstrain<FunASRQuantKind>, DefaultMarshaller<FunASRQuantKind>, FunASRQuantKindI18NAnnotation> funasrQuant{
        this, "FunASRQuant", "量化（CPU 提速档，GPU 无收益）",
        FunASRQuantKind::None};
    Option<std::string> funasrServerCmd{
        this, "FunASRServerCmd",
        "服务启动脚本路径（如 /opt/fcitx5-voice-input/scripts/funasr-serve.sh，"
        "支持 FUNASR_PORT/FUNASR_DEVICE/FUNASR_QUANT 环境变量）",
        ""};

    // —— 组2.2 FunASR 本地（GGUF 档）——
    Option<std::string> funasrLocalCmd{
        this, "FunASRLocalCmd", "llama-funasr-cli 可执行文件路径",
        "/usr/lib/fcitx5-voiceinput/llamacpp/llama-funasr-cli"};
    Option<std::string> funasrLocalModelDir{
        this, "FunASRLocalModelDir", "GGUF 模型目录（encoder/llm/vad/tiktoken）",
        "/usr/lib/fcitx5-voiceinput/gguf"};
    Option<std::string> funasrLocalQuant{
        this, "FunASRLocalQuant", "LLM 量化（q8_0=更准 或 q4km=更小）",
        "q8_0"};

    // —— 组3 Dummy 调试 ——
    Option<std::string> dummyText{
        this, "DummyText", "Dummy 输出文本（分号分隔多条轮换）",
        "这是语音输入的模拟结果。今天天气怎么样；我们出去玩吧；明天记得开会"};
    Option<bool> dummyStream{
        this, "DummyStream", "Dummy 模拟流式逐字上屏", true};
    Option<int> dummyStreamIntervalMs{
        this, "DummyStreamIntervalMs", "Dummy 流式逐字间隔（毫秒，20-2000）",
        120};

    // —— 组4 显示 ——
    Option<int> popupTimeoutMs{
        this, "PopupTimeoutMs", "结果停留时长（毫秒，200-10000，无候选时自动上屏）",
        1500};
);

} // namespace fcitx

#endif // _FCITX5_VOICEINPUT_CONFIG_H_
