cmake_minimum_required(VERSION 3.21)
project(virtpoint LANGUAGES C)

find_package(PkgConfig REQUIRED)
pkg_check_modules(WAYLAND REQUIRED IMPORTED_TARGET wayland-client)

find_program(WAYLAND_SCANNER_EXECUTABLE wayland-scanner REQUIRED)
set(XML ${CMAKE_CURRENT_SOURCE_DIR}/protocol/wlr-virtual-pointer-unstable-v1.xml)
set(GEN ${CMAKE_CURRENT_BINARY_DIR}/generated)
file(MAKE_DIRECTORY ${GEN})
add_custom_command(
    OUTPUT ${GEN}/vptr-protocol.c ${GEN}/wlr-virtual-pointer-unstable-v1-client-protocol.h
    COMMAND ${WAYLAND_SCANNER_EXECUTABLE} client-header ${XML} ${GEN}/wlr-virtual-pointer-unstable-v1-client-protocol.h
    COMMAND ${WAYLAND_SCANNER_EXECUTABLE} private-code ${XML} ${GEN}/vptr-protocol.c
    COMMAND sed -i "s/^WL_PRIVATE //g" ${GEN}/vptr-protocol.c
    DEPENDS ${XML}
    VERBATIM)

add_executable(virtpoint main.c ${GEN}/vptr-protocol.c)
target_include_directories(virtpoint PRIVATE ${GEN})
target_link_libraries(virtpoint PRIVATE PkgConfig::WAYLAND)

install(TARGETS virtpoint RUNTIME DESTINATION bin)
