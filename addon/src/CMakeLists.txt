add_library(voiceinput MODULE)
target_sources(voiceinput PRIVATE
    voiceinput.cpp
    popup_surface.cpp
    ui_bridge.cpp
)
# flutter bundle 安装位置（build.sh 拷入 dist；容器侧 /usr/lib/fcitx5-voiceinput/ui/bundle）
# 注意：不能用 CMAKE_INSTALL_FULL_LIBDIR——构建时 prefix 是 dist 暂存目录，
# 会把暂存路径编进二进制；这里要的是目标系统的运行时路径
set(VOICEINPUT_UI_LIBDIR "/usr/lib" CACHE STRING "Runtime libdir of flutter UI bundle")
target_compile_definitions(voiceinput PRIVATE
    VOICEINPUT_UI_PATH="${VOICEINPUT_UI_LIBDIR}/fcitx5-voiceinput/ui/bundle/voice_ui")
target_link_libraries(voiceinput PRIVATE Fcitx5::Core)
find_package(Fcitx5ModuleDBus CONFIG REQUIRED)
target_link_libraries(voiceinput PRIVATE Fcitx5::Module::DBus)
find_package(Fcitx5ModuleWayland CONFIG REQUIRED)
target_link_libraries(voiceinput PRIVATE Fcitx5::Module::Wayland)

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
target_include_directories(voiceinput PRIVATE ${GEN_DIR})
target_link_libraries(voiceinput PRIVATE wayland-client)
set_target_properties(voiceinput PROPERTIES PREFIX "")

install(TARGETS voiceinput LIBRARY DESTINATION "${FCITX_INSTALL_ADDONDIR}")

# addon 描述文件 → share/fcitx5/addon/
fcitx5_translate_desktop_file(voiceinput.conf.in voiceinput.conf)
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/voiceinput.conf"
        DESTINATION "${FCITX_INSTALL_PKGDATADIR}/addon")

# 输入法条目 → share/fcitx5/inputmethod/（文件名必须等于输入法唯一名）
fcitx5_translate_desktop_file(voiceinput-im.conf.in voiceinput-im.conf)
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/voiceinput-im.conf"
        DESTINATION "${FCITX_INSTALL_PKGDATADIR}/inputmethod"
        RENAME voiceinput.conf)
