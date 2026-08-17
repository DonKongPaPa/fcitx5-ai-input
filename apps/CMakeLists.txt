cmake_minimum_required(VERSION 3.21)
project(voiceinput-testapps VERSION 0.1.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(PkgConfig REQUIRED)

add_subdirectory(testapp-gtk)
add_subdirectory(testapp-qt)
