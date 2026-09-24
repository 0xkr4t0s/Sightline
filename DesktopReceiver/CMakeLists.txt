cmake_minimum_required(VERSION 3.25)
project(VCamReceiver
    VERSION 0.1.0
    DESCRIPTION "Enterprise virtual camera receiver driver"
    LANGUAGES CXX
)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# Platform detection
include(cmake/Platforms.cmake)

# Modular static libraries
add_subdirectory(src/core)
add_subdirectory(src/protocol)
add_subdirectory(src/network)
add_subdirectory(src/transport)
add_subdirectory(src/platform)
add_subdirectory(src/app)

# macOS CMIO extension (Phase 3)
if(APPLE)
    add_subdirectory(extension)
endif()

# Tests
option(VCAM_BUILD_TESTS "Build unit tests" ON)
if(VCAM_BUILD_TESTS)
    enable_testing()
    add_subdirectory(tests)
endif()
