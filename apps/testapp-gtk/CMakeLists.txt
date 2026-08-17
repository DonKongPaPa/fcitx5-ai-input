find_package(PkgConfig REQUIRED)
pkg_check_modules(GTK4 REQUIRED IMPORTED_TARGET gtk4)

add_executable(testapp-gtk testapp-gtk.c)
target_link_libraries(testapp-gtk PRIVATE PkgConfig::GTK4)
install(TARGETS testapp-gtk RUNTIME DESTINATION bin)
