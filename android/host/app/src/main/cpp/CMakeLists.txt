cmake_minimum_required(VERSION 3.22.1)
project(probnik_native LANGUAGES C CXX)

# C++ standard
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Source files
add_library(probnik_native SHARED
    probnik_native.cpp
    scenic_local/renderer_android.c
    scenic_local/comms.c
    scenic_local/script.c
    scenic_local/font.c
    scenic_local/image.c
    scenic_local/utils.c
    scenic_local/nanovg/nanovg.c
    scenic_local/nanovg_gl_impl.c
    scenic_local/tommyds/tommy.c
    scenic_local/tommyds/tommyhash.c
    scenic_local/tommyds/tommyhashlin.c
    scenic_local/tommyds/tommylist.c
    scenic_local/device/device_android.c
)

# Compiler warnings
target_compile_options(probnik_native PRIVATE
    -Wall
    -Wextra
    -Wno-unused-parameter
)

target_include_directories(probnik_native PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/scenic_local
    ${CMAKE_CURRENT_SOURCE_DIR}/scenic_local/tommyds
    ${CMAKE_CURRENT_SOURCE_DIR}/scenic_local/nanovg
    ${CMAKE_CURRENT_SOURCE_DIR}/scenic_local/device
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

# Include directories (for future OTP headers if needed)
# target_include_directories(probnik_native PRIVATE
#     ${CMAKE_SOURCE_DIR}/../../../../../_install/android-arm64/usr/local/lib/erlang/usr/include
# )

# Strip symbols in release builds (handled by Gradle, but explicit here)
if(CMAKE_BUILD_TYPE STREQUAL "Release")
    set_target_properties(probnik_native PROPERTIES
        LINK_FLAGS "-s"
    )
endif()
