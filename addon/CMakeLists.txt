cmake_minimum_required(VERSION 3.21)
project(fcitx5-voiceinput VERSION 0.1.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Arch 的 fcitx5 包拆分了上游伞形配置：Core 提供 Fcitx5::Core，Utils 提供 FCITX_INSTALL_* 变量
find_package(Fcitx5Core CONFIG REQUIRED)
find_package(Fcitx5Utils CONFIG REQUIRED)
message(STATUS "Found Fcitx5Core: ${Fcitx5Core_VERSION}")

# fcitx5_translate_desktop_file 需要 msgfmt 生成 conf
find_package(Gettext REQUIRED)

include(GNUInstallDirs)
add_subdirectory(src)
