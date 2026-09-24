# Phase 3: macOS CMIO system extension build
# Uses swiftc directly since CMake's Swift support doesn't handle system extensions well.

if(NOT APPLE)
    return()
endif()

set(EXTENSION_NAME "com.vcamblender.receiver.extension")
set(EXTENSION_BUNDLE_DIR "${CMAKE_BINARY_DIR}/extension/${EXTENSION_NAME}.systemextension")

set(SWIFT_SOURCES
    ${CMAKE_CURRENT_SOURCE_DIR}/main.swift
    ${CMAKE_CURRENT_SOURCE_DIR}/CMIOProvider.swift
    ${CMAKE_CURRENT_SOURCE_DIR}/CMIODevice.swift
    ${CMAKE_CURRENT_SOURCE_DIR}/CMIOStream.swift
)

# Find the macOS SDK
execute_process(
    COMMAND xcrun --sdk macosx --show-sdk-path
    OUTPUT_VARIABLE MACOS_SDK_PATH
    OUTPUT_STRIP_TRAILING_WHITESPACE
)

# Build the Swift extension as a standalone executable
add_custom_command(
    OUTPUT "${EXTENSION_BUNDLE_DIR}/Contents/MacOS/extension"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${EXTENSION_BUNDLE_DIR}/Contents/MacOS"
    COMMAND xcrun swiftc
        -sdk "${MACOS_SDK_PATH}"
        -target arm64-apple-macos14.0
        -O
        -module-name VCamExtension
        -o "${EXTENSION_BUNDLE_DIR}/Contents/MacOS/extension"
        ${SWIFT_SOURCES}
    COMMAND ${CMAKE_COMMAND} -E copy
        "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist"
        "${EXTENSION_BUNDLE_DIR}/Contents/Info.plist"
    DEPENDS ${SWIFT_SOURCES}
    COMMENT "Building CMIO extension"
    VERBATIM
)

add_custom_target(vcam_extension ALL
    DEPENDS "${EXTENSION_BUNDLE_DIR}/Contents/MacOS/extension"
)
