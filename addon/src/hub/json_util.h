#ifndef _FCITX5_AIINPUT_HUB_JSON_UTIL_H_
#define _FCITX5_AIINPUT_HUB_JSON_UTIL_H_

#include <string>

namespace fcitx {

// JSON 字符串转义（候选文本走 UTF-8 原样，只处理控制字符）。
// 独立小文件的原因：UI 插件化拆分后 flutter_engine.cpp 只编进 aiinput-ui
// target，而引擎侧（字体下发/refine 请求/健康检查）与 UI 侧（ui_bus、
// panel 翻译）都要用——两侧各自链接本文件，避免跨 addon 符号依赖。
std::string flutterJsonEscape(const std::string &s);

} // namespace fcitx

#endif // _FCITX5_AIINPUT_HUB_JSON_UTIL_H_
