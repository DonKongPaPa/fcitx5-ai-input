add_library(voiceinput MODULE)
target_sources(voiceinput PRIVATE
    voiceinput.cpp
    popup_surface.cpp
    flutter_engine.cpp
    funasr_ws_engine.cpp
    funasr_local_engine.cpp
    sherpa_engine.cpp
)
target_link_libraries(voiceinput PRIVATE Fcitx5::Core)
find_package(Fcitx5ModuleDBus CONFIG REQUIRED)
target_link_libraries(voiceinput PRIVATE Fcitx5::Module::DBus)
find_package(Fcitx5ModuleWayland CONFIG REQUIRED)
target_link_libraries(voiceinput PRIVATE Fcitx5::Module::Wayland)

# —— Flutter raw embedder 引擎（进程内嵌入，软渲染）——
# 头文件 vendor 在 addon/third_party/；libflutter_engine.so 由
# scripts/fetch-flutter-embedder.sh 下载到 .cache/flutter-embedder/
#（官方工件只有 linux-x64/JIT 变体；release 目录仅 GTK 壳不导出 C API）。
# 打包/容器构建可 -DFLUTTER_ENGINE_LIBRARY=... 显式指定。
set(FLUTTER_ENGINE_LIBRARY "" CACHE PATH "libflutter_engine.so 路径")
if(NOT FLUTTER_ENGINE_LIBRARY)
    set(FLUTTER_ENGINE_LIBRARY "${CMAKE_CURRENT_SOURCE_DIR}/../../.cache/flutter-embedder/libflutter_engine.so")
endif()
if(NOT EXISTS "${FLUTTER_ENGINE_LIBRARY}")
    message(FATAL_ERROR
        "libflutter_engine.so 未找到：${FLUTTER_ENGINE_LIBRARY}\n"
        "先运行 scripts/fetch-flutter-embedder.sh，或传 -DFLUTTER_ENGINE_LIBRARY=/path/to/libflutter_engine.so")
endif()
target_compile_definitions(voiceinput PRIVATE
    VOICEINPUT_VERSION_STRING="${PROJECT_VERSION}")
target_include_directories(voiceinput PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../third_party")
target_link_libraries(voiceinput PRIVATE "${FLUTTER_ENGINE_LIBRARY}")

# —— sherpa-onnx 运行时（CPU 流式第四引擎）——
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
target_link_libraries(voiceinput PRIVATE "${SHERPA_ONNX_LIBRARY}")
target_link_libraries(voiceinput PRIVATE pthread)

# W4 字体跟随：fontconfig 解析 classicui Font → 字体文件
find_package(PkgConfig REQUIRED)
pkg_check_modules(FONTCONFIG REQUIRED IMPORTED_TARGET fontconfig)
target_link_libraries(voiceinput PRIVATE PkgConfig::FONTCONFIG)

# input-method-v2 协议（wlroots/fcitx5 扩展，不在 wayland-protocols 包内）
find_program(WAYLAND_SCANNER_EXECUTABLE wayland-scanner REQUIRED)
set(IM_V2_XML ${CMAKE_CURRENT_SOURCE_DIR}/../protocol/input-method-unstable-v2.xml)
set(GEN_DIR ${CMAKE_CURRENT_BINARY_DIR}/generated)
file(MAKE_DIRECTORY ${GEN_DIR})
add_custom_command(
    # client header 用上游标准文件名：vendored fcitx-wayland wrapper 以该名 include
    OUTPUT ${GEN_DIR}/imv2-protocol.c
           ${GEN_DIR}/wayland-input-method-unstable-v2-client-protocol.h
    COMMAND ${WAYLAND_SCANNER_EXECUTABLE} client-header ${IM_V2_XML} ${GEN_DIR}/wayland-input-method-unstable-v2-client-protocol.h
    COMMAND ${WAYLAND_SCANNER_EXECUTABLE} private-code ${IM_V2_XML} ${GEN_DIR}/imv2-protocol.c
    # wayland-scanner 会把 wl_interface 定义标记 WL_PRIVATE(hidden)，跨编译单元
    # 无法解析——去掉让符号在模块内可见
    COMMAND sed -i "s/^WL_PRIVATE //g" ${GEN_DIR}/imv2-protocol.c
    COMMAND sed -i "s/^extern const struct wl_interface/extern __attribute__((visibility(\"default\"))) const struct wl_interface/" ${GEN_DIR}/imv2-protocol.c
    DEPENDS ${IM_V2_XML}
    VERBATIM)
target_sources(voiceinput PRIVATE ${GEN_DIR}/imv2-protocol.c)

# —— W3 fractional scale：viewporter + fractional-scale-v1（wayland-protocols 标准件）——
foreach(proto viewporter fractional-scale-v1)
    add_custom_command(
        OUTPUT ${GEN_DIR}/${proto}-protocol.c
               ${GEN_DIR}/${proto}-client-protocol.h
        COMMAND ${WAYLAND_SCANNER_EXECUTABLE} client-header
                ${CMAKE_CURRENT_SOURCE_DIR}/../protocol/${proto}.xml
                ${GEN_DIR}/${proto}-client-protocol.h
        COMMAND ${WAYLAND_SCANNER_EXECUTABLE} private-code
                ${CMAKE_CURRENT_SOURCE_DIR}/../protocol/${proto}.xml
                ${GEN_DIR}/${proto}-protocol.c
        COMMAND sed -i "s/^WL_PRIVATE //g" ${GEN_DIR}/${proto}-protocol.c
        COMMAND sed -i "s/^extern const struct wl_interface/extern __attribute__((visibility(\"default\"))) const struct wl_interface/" ${GEN_DIR}/${proto}-protocol.c
        DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/../protocol/${proto}.xml
        VERBATIM)
    target_sources(voiceinput PRIVATE ${GEN_DIR}/${proto}-protocol.c)
endforeach()
target_include_directories(voiceinput PRIVATE ${GEN_DIR})
target_link_libraries(voiceinput PRIVATE wayland-client)
set_target_properties(voiceinput PROPERTIES PREFIX "")

# 引擎 .so 装到 addon 旁的私有目录（libdir/fcitx5-voiceinput），rpath 用
# $ORIGIN 相对定位（无需 LD_LIBRARY_PATH）。路径必须前缀相对——dist 暂存
# 打包依赖 CMAKE_INSTALL_PREFIX
install(FILES "${FLUTTER_ENGINE_LIBRARY}"
        DESTINATION "${CMAKE_INSTALL_LIBDIR}/fcitx5-voiceinput")
get_filename_component(SHERPA_RT_DIR "${SHERPA_ONNX_LIBRARY}" DIRECTORY)
install(FILES "${SHERPA_RT_DIR}/libsherpa-onnx-c-api.so"
              "${SHERPA_RT_DIR}/libonnxruntime.so"
        DESTINATION "${CMAKE_INSTALL_LIBDIR}/fcitx5-voiceinput")
get_filename_component(FLUTTER_ENGINE_DIR "${FLUTTER_ENGINE_LIBRARY}" DIRECTORY)
set_target_properties(voiceinput PROPERTIES
    BUILD_RPATH "${FLUTTER_ENGINE_DIR}"
    INSTALL_RPATH "$ORIGIN/../fcitx5-voiceinput")

install(TARGETS voiceinput LIBRARY DESTINATION "${FCITX_INSTALL_ADDONDIR}")

# addon 描述文件 → share/fcitx5/addon/
# fcitx5_translate_desktop_file 只做 i18n 不替换 @VAR@——直接 configure_file
# （addon conf 不需要 i18n 翻译，Version 必须被替换）
configure_file(voiceinput.conf.in voiceinput.conf @ONLY)
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/voiceinput.conf"
        DESTINATION "${FCITX_INSTALL_PKGDATADIR}/addon")

# Flutter 资产（flutter_assets + icudtl.dat）→ share/fcitx5-voiceinput/flutter/
# 产物由 flutter build bundle 生成；此处可选安装（构建机上有才装，打包
# 脚本也可能自行拷贝）。VOICEINPUT_FLUTTER_ASSETS_DIR 指向含 flutter_assets/
# 与 icudtl.dat 的目录。
set(VOICEINPUT_FLUTTER_ASSETS_DIR "" CACHE PATH "flutter_assets+icudtl.dat 所在目录")
if(VOICEINPUT_FLUTTER_ASSETS_DIR AND EXISTS "${VOICEINPUT_FLUTTER_ASSETS_DIR}/flutter_assets")
    install(DIRECTORY "${VOICEINPUT_FLUTTER_ASSETS_DIR}/flutter_assets"
            DESTINATION "${CMAKE_INSTALL_DATADIR}/fcitx5-voiceinput/flutter")
    install(FILES "${VOICEINPUT_FLUTTER_ASSETS_DIR}/icudtl.dat"
            DESTINATION "${CMAKE_INSTALL_DATADIR}/fcitx5-voiceinput/flutter"
            OPTIONAL)
endif()
