add_library(aiinput MODULE)
# 模块拆分蓝图（lab/spec/ui-split-contract.md）：进程内双 addon——
# 本 target = 引擎（core=会话状态机/按键/配置  hub=协议发射  asr=识别后端）；
# UI 侧三目录已迁去 addon/ui/ 的 aiinputui target，两侧经 hub/ui_split_iface.h 对调
target_sources(aiinput PRIVATE
    core/aiinput.cpp
    hub/ui_bus.cpp
    hub/stdio_backend.cpp
    hub/json_util.cpp
    asr/funasr_ws_engine.cpp
    asr/funasr_local_engine.cpp
    asr/sherpa_engine.cpp
    asr/stdio_engine.cpp
)
target_include_directories(aiinput PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}"
    "${CMAKE_CURRENT_SOURCE_DIR}/core"
    "${CMAKE_CURRENT_SOURCE_DIR}/hub"
    "${CMAKE_CURRENT_SOURCE_DIR}/asr"
    # sherpa-onnx SDK 头（asr 引擎 include "sherpa-onnx/c-api.h"）；
    # flutter_embedder.h 同住此目录但只有 ui 侧用
    "${CMAKE_CURRENT_SOURCE_DIR}/../third_party")
target_link_libraries(aiinput PRIVATE Fcitx5::Core)
# 5.0（bookworm 5.0.21）没有 CandidateWord::comment()（5.1 API）——
# 按检测到的版本出宏，源码里降级
if(Fcitx5Core_VERSION VERSION_GREATER_EQUAL 5.1)
    target_compile_definitions(aiinput PRIVATE AIINPUT_FCITX_GE_51=1)
endif()
find_package(Fcitx5ModuleDBus CONFIG REQUIRED)
target_link_libraries(aiinput PRIVATE Fcitx5::Module::DBus)
target_compile_definitions(aiinput PRIVATE
    AIINPUT_VERSION_STRING="${PROJECT_VERSION}")

# —— sherpa-onnx 运行时（CPU 流式识别引擎）——
# libsherpa-onnx-c-api.so（自带 RPATH $ORIGIN，libonnxruntime.so 同目录解析）
set(SHERPA_ONNX_LIBRARY "" CACHE PATH "libsherpa-onnx-c-api.so 路径")
if(NOT SHERPA_ONNX_LIBRARY)
    set(SHERPA_ONNX_LIBRARY "${CMAKE_CURRENT_SOURCE_DIR}/../../.cache/sherpa-onnx/libsherpa-onnx-c-api.so")
endif()
if(NOT EXISTS "${SHERPA_ONNX_LIBRARY}")
    message(FATAL_ERROR
        "libsherpa-onnx-c-api.so 未找到：${SHERPA_ONNX_LIBRARY}\n"
        "先运行 scripts/fetch-sherpa-runtime.sh，或传 -DSHERPA_ONNX_LIBRARY=...")
endif()
target_link_libraries(aiinput PRIVATE "${SHERPA_ONNX_LIBRARY}")
target_link_libraries(aiinput PRIVATE pthread)

# W4 字体跟随：fontconfig 解析 classicui Font → 字体文件
find_package(PkgConfig REQUIRED)
pkg_check_modules(FONTCONFIG REQUIRED IMPORTED_TARGET fontconfig)
target_link_libraries(aiinput PRIVATE PkgConfig::FONTCONFIG)
set_target_properties(aiinput PROPERTIES PREFIX "")

# sherpa 运行时库装到 addon 旁的私有目录（libdir/fcitx5-aiinput），rpath 用
# $ORIGIN 相对定位（无需 LD_LIBRARY_PATH）。路径必须前缀相对——dist 暂存
# 打包依赖 CMAKE_INSTALL_PREFIX
get_filename_component(SHERPA_RT_DIR "${SHERPA_ONNX_LIBRARY}" DIRECTORY)
install(FILES "${SHERPA_RT_DIR}/libsherpa-onnx-c-api.so"
              "${SHERPA_RT_DIR}/libonnxruntime.so"
        DESTINATION "${CMAKE_INSTALL_LIBDIR}/fcitx5-aiinput")
set_target_properties(aiinput PROPERTIES
    INSTALL_RPATH "$ORIGIN/../fcitx5-aiinput")

install(TARGETS aiinput LIBRARY DESTINATION "${FCITX_INSTALL_ADDONDIR}")

# addon 描述文件 → share/fcitx5/addon/
# fcitx5_translate_desktop_file 只做 i18n 不替换 @VAR@——直接 configure_file
# （addon conf 不需要 i18n 翻译，Version 必须被替换）
configure_file(aiinput.conf.in aiinput.conf @ONLY)
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/aiinput.conf"
        DESTINATION "${FCITX_INSTALL_PKGDATADIR}/addon")

# v1 协议 stdio 后端脚本（P6：asr/refine 进程外；StdioAsrCmd/StdioRefineCmd
# 默认指向此安装路径）。参照实现 + 可直接替换成真实后端
install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/../../backends/asr-dummy.py"
              "${CMAKE_CURRENT_SOURCE_DIR}/../../backends/refine-dummy.py"
        DESTINATION "${CMAKE_INSTALL_DATADIR}/fcitx5-aiinput/backends")
