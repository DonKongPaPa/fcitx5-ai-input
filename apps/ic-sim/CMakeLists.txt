# ic-sim：纯 D-Bus IC 模拟器（addon-test 容器，无显示）
pkg_check_modules(GIO REQUIRED IMPORTED_TARGET gio-2.0)
add_executable(ic-sim ic-sim.c)
target_link_libraries(ic-sim PkgConfig::GIO)
install(TARGETS ic-sim DESTINATION bin)
