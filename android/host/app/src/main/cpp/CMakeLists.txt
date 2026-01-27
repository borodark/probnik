cmake_minimum_required(VERSION 3.22.1)
project(probnik_native LANGUAGES C CXX)

# C/C++ standards
set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Path to scenic_renderer_native (7 levels up from cpp/ to learn_erl/)
set(SCENIC_RENDERER_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../../../scenic_renderer_native")

# scenic_renderer_native source files
set(SCENIC_RENDERER_SOURCES
    ${SCENIC_RENDERER_DIR}/src/scenic_renderer.c
    ${SCENIC_RENDERER_DIR}/src/protocol.c
    ${SCENIC_RENDERER_DIR}/src/comms.c
    ${SCENIC_RENDERER_DIR}/src/script.c
    ${SCENIC_RENDERER_DIR}/src/font.c
    ${SCENIC_RENDERER_DIR}/src/image.c
    ${SCENIC_RENDERER_DIR}/src/utils.c
    ${SCENIC_RENDERER_DIR}/src/transport/transport.c
    ${SCENIC_RENDERER_DIR}/src/transport/unix_socket.c
    ${SCENIC_RENDERER_DIR}/src/transport/tcp.c
    ${SCENIC_RENDERER_DIR}/src/nanovg/nanovg.c
    ${SCENIC_RENDERER_DIR}/src/tommyds/tommy.c
    ${SCENIC_RENDERER_DIR}/src/tommyds/tommyhash.c
    ${SCENIC_RENDERER_DIR}/src/tommyds/tommyhashlin.c
    ${SCENIC_RENDERER_DIR}/src/tommyds/tommylist.c
    ${SCENIC_RENDERER_DIR}/src/platform/android/platform_android.c
)

# Main library
add_library(probnik_native SHARED
    probnik_native.cpp
    ${SCENIC_RENDERER_SOURCES}
)

# Compiler warnings
target_compile_options(probnik_native PRIVATE
    -Wall
    -Wextra
    -Wno-unused-parameter
)

# Include directories
target_include_directories(probnik_native PRIVATE
    ${SCENIC_RENDERER_DIR}/include
    ${SCENIC_RENDERER_DIR}/src
    ${SCENIC_RENDERER_DIR}/src/nanovg
    ${SCENIC_RENDERER_DIR}/src/tommyds
)

# Find required libraries
find_library(log-lib log)
find_library(android-lib android)
find_library(gles-lib GLESv3)
find_library(egl-lib EGL)
find_library(m-lib m)

# Link libraries
target_link_libraries(probnik_native
    ${log-lib}
    ${android-lib}
    ${gles-lib}
    ${egl-lib}
    ${m-lib}
)

# Strip symbols in release builds
if(CMAKE_BUILD_TYPE STREQUAL "Release")
    set_target_properties(probnik_native PROPERTIES
        LINK_FLAGS "-s"
    )
endif()
