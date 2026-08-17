find_package(Qt6 REQUIRED COMPONENTS Widgets)
qt_standard_project_setup()

add_executable(testapp-qt testapp-qt.cpp)
target_link_libraries(testapp-qt PRIVATE Qt6::Widgets)
install(TARGETS testapp-qt RUNTIME DESTINATION bin)
