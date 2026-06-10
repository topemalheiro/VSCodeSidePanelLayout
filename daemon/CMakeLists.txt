cmake_minimum_required(VERSION 3.20)
project(reprompty-layoutd VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

find_package(PkgConfig REQUIRED)
pkg_check_modules(DBUS REQUIRED dbus-1)

find_package(Threads REQUIRED)

# Boost JSON
find_library(BOOST_JSON_LIB boost_json PATHS /usr/lib64 /usr/lib)
if(NOT BOOST_JSON_LIB)
    message(FATAL_ERROR "libboost_json not found")
endif()

add_executable(reprompty-layoutd
    src/main.cpp
    src/daemon.cpp
    src/kwin_dbus.cpp
    src/layout_engine.cpp
    src/cdp_manager.cpp
)

target_include_directories(reprompty-layoutd PRIVATE
    ${DBUS_INCLUDE_DIRS}
    ${DBUS_INCLUDE_DIRS}/dbus
)

target_compile_options(reprompty-layoutd PRIVATE
    ${DBUS_CFLAGS_OTHER}
    -Wall -Wextra -O2
)

target_link_libraries(reprompty-layoutd PRIVATE
    ${DBUS_LIBRARIES}
    ${BOOST_JSON_LIB}
    Threads::Threads
)

# Client binary
add_executable(reprompty-layout
    ../client/src/main.cpp
)

target_link_libraries(reprompty-layout PRIVATE Threads::Threads)

# Install
install(TARGETS reprompty-layoutd reprompty-layout
    RUNTIME DESTINATION bin
)
