# Platform detection macros for VCamReceiver

if(APPLE)
    set(VCAM_PLATFORM_MACOS TRUE)
    message(STATUS "VCam: Building for macOS")

    # Enable ObjC++ for CMIO bridge
    enable_language(OBJCXX)
    set(CMAKE_OBJCXX_STANDARD 20)
elseif(UNIX AND NOT APPLE)
    set(VCAM_PLATFORM_LINUX TRUE)
    message(STATUS "VCam: Building for Linux")
elseif(WIN32)
    set(VCAM_PLATFORM_WINDOWS TRUE)
    message(STATUS "VCam: Building for Windows")
else()
    message(FATAL_ERROR "VCam: Unsupported platform")
endif()
