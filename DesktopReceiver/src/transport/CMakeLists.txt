add_library(vcam_transport STATIC
    TrackingRelay.cpp
)

target_include_directories(vcam_transport PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}
)

target_link_libraries(vcam_transport PUBLIC
    vcam_protocol
    vcam_network
)
