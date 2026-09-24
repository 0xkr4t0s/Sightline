add_library(vcam_platform STATIC)

target_include_directories(vcam_platform PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}
)

target_link_libraries(vcam_platform PUBLIC vcam_core)

if(VCAM_PLATFORM_MACOS)
    target_sources(vcam_platform PRIVATE
        macos/CMIOBridge.mm
    )
    target_link_libraries(vcam_platform PUBLIC
        "-framework CoreMediaIO"
        "-framework CoreMedia"
        "-framework CoreVideo"
        "-framework Foundation"
    )
elseif(VCAM_PLATFORM_LINUX)
    target_sources(vcam_platform PRIVATE
        linux/V4L2LoopbackCamera.cpp
    )
elseif(VCAM_PLATFORM_WINDOWS)
    target_sources(vcam_platform PRIVATE
        windows/DirectShowCamera.cpp
    )
endif()
