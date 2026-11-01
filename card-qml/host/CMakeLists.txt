# aiinput-card-host：frame-relay 离屏渲染宿主（lab/spec/frame-relay.md）。
# 软件 API + QQuickRenderControl：无窗口离屏渲染，独立进程 = 崩溃隔离。
# 调用方（addon/ui/CMakeLists.txt）已做 Qt6 QUIET 探测，此处 REQUIRED。
set(CMAKE_AUTOMOC ON)
find_package(Qt6 REQUIRED COMPONENTS Core Gui Quick)
add_executable(aiinput-card-host card_host.cpp)
target_link_libraries(aiinput-card-host PRIVATE Qt6::Core Qt6::Gui Qt6::Quick)
# 与 addon 同目录族（libdir/fcitx5）；ui_addon 的 relay 默认 spawn 指此路径
install(TARGETS aiinput-card-host
        RUNTIME DESTINATION "${CMAKE_INSTALL_LIBDIR}/fcitx5")
