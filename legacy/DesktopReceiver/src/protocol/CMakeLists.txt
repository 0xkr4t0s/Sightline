add_library(vcam_protocol STATIC
    FreeDParser.cpp
    LiveLinkParser.cpp
)

target_include_directories(vcam_protocol PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}
)

target_link_libraries(vcam_protocol PUBLIC vcam_core)
