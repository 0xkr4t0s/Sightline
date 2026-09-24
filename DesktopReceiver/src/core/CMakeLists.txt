add_library(vcam_core STATIC
    IVirtualCamera.cpp
    FrameBuffer.cpp
    PluginRegistry.cpp
)

target_include_directories(vcam_core PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}
)
