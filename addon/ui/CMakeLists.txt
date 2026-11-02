add_library(aiinputui MODULE)
# UI addon target（UI 插件化拆分，lab/spec/ui-split-contract.md §5）：
# ui=UserInterface/Flutter 接线  surfaces=定位三路径  embedder=Flutter raw
# embedder；hub 的 ui_bus/json_util 编进两侧 target（各持私有副本，MODULE
# 默认 hidden visibility，无跨 .so 符号需求，见契约 §6）
target_sources(aiinputui PRIVATE
    ui_addon.cpp
    socket_ui.cpp
    surfaces/popup_surface.cpp
    embedder/flutter_engine.cpp
    ../src/hub/ui_bus.cpp
    ../src/hub/json_util.cpp
)
# 本目录（ui 根）必须在搜索路径里：popup_surface.cpp 以 "fcitx-wayland/…"
# 相对路径引用迁过来的 wayland 包装头
target_include_directories(aiinputui PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}"
    "${CMAKE_CURRENT_SOURCE_DIR}/surfaces"
    "${CMAKE_CURRENT_SOURCE_DIR}/embedder"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/hub"
    "${CMAKE_CURRENT_SOURCE_DIR}/../third_party")
target_link_libraries(aiinputui PRIVATE Fcitx5::Core)
# 5.0（bookworm 5.0.21）没有 CandidateWord::comment()（5.1 API）——
# 按检测到的版本出宏，源码里降级（与引擎 target 同款守卫）
if(Fcitx5Core_VERSION VERSION_GREATER_EQUAL 5.1)
    target_compile_definitions(aiinputui PRIVATE AIINPUT_FCITX_GE_51=1)
endif()
target_compile_definitions(aiinputui PRIVATE
    AIINPUT_VERSION_STRING="${PROJECT_VERSION}")

find_package(Fcitx5ModuleWayland CONFIG REQUIRED)
# tray 使能接管（classicui 挂起会 disable SNI，活跃 UI 补位使能）
find_package(Fcitx5ModuleNotificationItem CONFIG REQUIRED)
target_link_libraries(aiinputui PRIVATE Fcitx5::Module::Wayland Fcitx5::Module::NotificationItem)
# XWayland 矩形换算：xcb 主显示判定（isXWayland）+ 独立 xcb 连接查
# _NET_ACTIVE_WINDOW/WM_CLASS/输出区段（无 X 环境自动跳过）。
# 坑：Fcitx5::Module::XCB 是 INTERFACE 目标只给头文件路径，libxcb
# 必须显式链——惰性绑定下漏链在无 X 的容器里测不出（符号从未解析），
# 上机一调 xcb_connect 即 symbol lookup error 崩掉 fcitx5
find_package(Fcitx5ModuleXCB CONFIG REQUIRED)
target_link_libraries(aiinputui PRIVATE Fcitx5::Module::XCB)
# libxcb 链接统一走下方 PkgConfig 声明
find_package(PkgConfig REQUIRED)
pkg_check_modules(XCB REQUIRED IMPORTED_TARGET xcb xcb-shm)
target_link_libraries(aiinputui PRIVATE PkgConfig::XCB)

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
target_link_libraries(aiinputui PRIVATE "${FLUTTER_ENGINE_LIBRARY}")

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
target_sources(aiinputui PRIVATE ${GEN_DIR}/imv2-protocol.c)

# —— W3 fractional scale：viewporter + fractional-scale-v1（wayland-protocols 标准件）——
foreach(proto viewporter fractional-scale-v1 wlr-layer-shell cursor-shape-v1 xdg-output-unstable-v1)
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
        # wlr-layer-shell 的 get_layer_surface 参数名 namespace 撞 C++ 关键字
        COMMAND sed -i "s/\\bnamespace\\b/namespace_/g" ${GEN_DIR}/${proto}-client-protocol.h
        DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/../protocol/${proto}.xml
        VERBATIM)
    target_sources(aiinputui PRIVATE ${GEN_DIR}/${proto}-protocol.c)
endforeach()
target_include_directories(aiinputui PRIVATE ${GEN_DIR})
target_link_libraries(aiinputui PRIVATE wayland-client)
set_target_properties(aiinputui PROPERTIES PREFIX "")
target_link_libraries(aiinputui PRIVATE pthread)

# 引擎 .so 装到 addon 旁的私有目录（libdir/fcitx5-aiinput），rpath 用
# $ORIGIN 相对定位（无需 LD_LIBRARY_PATH）。路径必须前缀相对——dist 暂存
# 打包依赖 CMAKE_INSTALL_PREFIX
install(FILES "${FLUTTER_ENGINE_LIBRARY}"
        DESTINATION "${CMAKE_INSTALL_LIBDIR}/fcitx5-aiinput")
get_filename_component(FLUTTER_ENGINE_DIR "${FLUTTER_ENGINE_LIBRARY}" DIRECTORY)
set_target_properties(aiinputui PROPERTIES
    BUILD_RPATH "${FLUTTER_ENGINE_DIR}"
    INSTALL_RPATH "$ORIGIN/../fcitx5-aiinput")

install(TARGETS aiinputui LIBRARY DESTINATION "${FCITX_INSTALL_ADDONDIR}")

# addon 描述文件 → share/fcitx5/addon/
# fcitx5_translate_desktop_file 只做 i18n 不替换 @VAR@——直接 configure_file
# （addon conf 不需要 i18n 翻译，Version 必须被替换）
configure_file(aiinput-ui.conf.in aiinput-ui.conf @ONLY)
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/aiinput-ui.conf"
        DESTINATION "${FCITX_INSTALL_PKGDATADIR}/addon")

# QML 卡片原型随包安装（QmlCardCmd 默认指向此路径；__pycache__ 不入）
install(DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../../card-qml"
        DESTINATION "${CMAKE_INSTALL_DATADIR}/fcitx5-aiinput"
        FILES_MATCHING
        PATTERN "*.qml" PATTERN "*.py" PATTERN "README.md")

# Flutter 资产（flutter_assets + icudtl.dat）→ share/fcitx5-aiinput/flutter/
# 产物由 flutter build bundle 生成；此处可选安装（构建机上有才装，打包
# 脚本也可能自行拷贝）。AIINPUT_FLUTTER_ASSETS_DIR 指向含 flutter_assets/
# 与 icudtl.dat 的目录。
set(AIINPUT_FLUTTER_ASSETS_DIR "" CACHE PATH "flutter_assets+icudtl.dat 所在目录")
if(AIINPUT_FLUTTER_ASSETS_DIR AND EXISTS "${AIINPUT_FLUTTER_ASSETS_DIR}/flutter_assets")
    install(DIRECTORY "${AIINPUT_FLUTTER_ASSETS_DIR}/flutter_assets"
            DESTINATION "${CMAKE_INSTALL_DATADIR}/fcitx5-aiinput/flutter")
    install(FILES "${AIINPUT_FLUTTER_ASSETS_DIR}/icudtl.dat"
            DESTINATION "${CMAKE_INSTALL_DATADIR}/fcitx5-aiinput/flutter"
            OPTIONAL)
endif()

# —— aiinput-card-host（frame-relay 离屏渲染宿主，lab/spec/frame-relay.md）——
# Qt6 QUIET 探测：缺席则宿主跳过（纯 fcitx addon 构建不强制依赖 Qt；
# relayed QML 卡随之停用，direct/Flutter 路径不受影响）
find_package(Qt6 COMPONENTS Core Gui Quick QUIET)
if(Qt6_FOUND)
    add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../../card-qml/host"
                     "${CMAKE_CURRENT_BINARY_DIR}/card-host")
    message(STATUS "aiinput-card-host: Qt6 ${Qt6_VERSION} 离屏渲染宿主启用")
else()
    message(STATUS "aiinput-card-host: Qt6 未找到——QML relay 停用")
endif()

# relay 模式默认 spawn 的宿主/QML 路径（install 布局单源，跨发行版 libdir）
target_compile_definitions(aiinputui PRIVATE
    AIINPUT_CARD_HOST_PATH="${CMAKE_INSTALL_FULL_LIBDIR}/fcitx5/aiinput-card-host"
    AIINPUT_CARD_QML_DIR="${CMAKE_INSTALL_FULL_DATADIR}/fcitx5-aiinput/card-qml")
