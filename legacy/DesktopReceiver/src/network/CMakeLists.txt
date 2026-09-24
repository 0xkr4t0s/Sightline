add_library(vcam_network STATIC
    UDPReceiver.cpp
    MDNSAdvertiser.cpp
)

target_include_directories(vcam_network PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}
)
