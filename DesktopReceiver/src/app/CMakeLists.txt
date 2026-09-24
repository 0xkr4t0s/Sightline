add_executable(VCamReceiver
    main.cpp
    ReceiverEngine.cpp
    TestPatternGenerator.cpp
)

target_link_libraries(VCamReceiver PRIVATE
    vcam_core
    vcam_protocol
    vcam_network
    vcam_transport
    vcam_platform
)
