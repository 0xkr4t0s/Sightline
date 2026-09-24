include(FetchContent)
FetchContent_Declare(
    googletest
    GIT_REPOSITORY https://github.com/google/googletest.git
    GIT_TAG v1.14.0
)
FetchContent_MakeAvailable(googletest)

add_executable(vcam_tests
    test_freed_parser.cpp
    test_udp_receiver.cpp
)

target_link_libraries(vcam_tests PRIVATE
    vcam_protocol
    vcam_network
    vcam_core
    GTest::gtest_main
)

include(GoogleTest)
gtest_discover_tests(vcam_tests)
