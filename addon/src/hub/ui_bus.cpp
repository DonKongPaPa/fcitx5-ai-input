#include "ui_bus.h"

#include <cstdint>
#include <sstream>



namespace fcitx {

void UiBus::theme(const std::string &fontPath, double size, double anim) {
    std::ostringstream o;
    o << "{\"font_path\":\"" << flutterJsonEscape(fontPath)
      << "\",\"font_size\":" << size << ",\"anim\":" << anim << "}";
    send("theme", o.str());
}

void UiBus::voiceRecording(const std::string &partial, uint64_t elapsedMs,
                           double anim) {
    std::ostringstream o;
    o << "{\"partial\":\"" << flutterJsonEscape(partial)
      << "\",\"elapsed_ms\":" << elapsedMs << ",\"anim\":" << anim << "}";
    send("voice/recording", o.str());
}

void UiBus::voiceResult(const std::string &finalText, int timeoutMs,
                        double anim) {
    std::ostringstream o;
    o << "{\"final\":\"" << flutterJsonEscape(finalText)
      << "\",\"timeout_ms\":" << timeoutMs << ",\"anim\":" << anim << "}";
    send("voice/result", o.str());
}

void UiBus::voiceCandidates(const std::string &finalText,
                            const std::vector<std::string> &candidates,
                            int hover, bool llmDummy, double anim) {
    std::ostringstream o;
    o << "{\"final\":\"" << flutterJsonEscape(finalText) << "\",\"candidates\":[";
    for (size_t i = 0; i < candidates.size(); ++i) {
        if (i) {
            o << ",";
        }
        o << "\"" << flutterJsonEscape(candidates[i]) << "\"";
    }
    o << "],\"hover\":" << hover << ",\"llm_dummy\":" << llmDummy
      << ",\"anim\":" << anim << "}";
    send("voice/candidates", o.str());
}

void UiBus::voiceIdle(double anim) {
    std::ostringstream o;
    o << "{\"anim\":" << anim << "}";
    send("voice/idle", o.str());
}

} // namespace fcitx
