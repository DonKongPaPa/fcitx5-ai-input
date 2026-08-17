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

// ASR 引擎：Dummy=调试用模拟输出（默认）；FunASR=预留接入点
FCITX_CONFIG_ENUM(AsrEngineKind, Dummy, FunASR);
FCITX_CONFIG_ENUM_I18N_ANNOTATION(AsrEngineKind, "Dummy", "FunASR");

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
    Option<AsrEngineKind, NoConstrain<AsrEngineKind>, DefaultMarshaller<AsrEngineKind>, AsrEngineKindI18NAnnotation> asrEngine{
        this, "AsrEngine", "ASR 引擎（Dummy=调试模拟，FunASR=预留）",
        AsrEngineKind::Dummy};
    Option<bool> streamingEnabled{
        this, "StreamingEnabled", "流式识别（实时显示中间结果，引擎支持时）",
        true};
    Option<bool> llmEnabled{
        this, "LLMEnabled", "LLM 优化输出（开启时结果先入候选框）", true};

    // —— 组3 Dummy 调试 ——
    Option<std::string> dummyText{
        this, "DummyText", "Dummy 输出文本（分号分隔多条轮换）",
        "这是语音输入的模拟结果。今天天气怎么样；我们出去玩吧；明天记得开会"};
    Option<int> dummyDelayMs{
        this, "DummyDelayMs", "Dummy 非流式识别延迟（毫秒，0-5000）", 800};
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
