# macOS code signing helpers for CMIO system extension
# Phase 3: Used when building the CMIO extension bundle

# The CMIO extension must be signed with a valid Developer ID
# and embedded inside the host app bundle at:
#   Contents/Library/SystemExtensions/<extension>.systemextension

function(vcam_codesign TARGET)
    if(NOT APPLE)
        return()
    endif()

    # Placeholder — actual signing identity configured via:
    #   -DVCAM_CODESIGN_IDENTITY="Developer ID Application: ..."
    if(DEFINED VCAM_CODESIGN_IDENTITY)
        add_custom_command(TARGET ${TARGET} POST_BUILD
            COMMAND codesign --force --sign "${VCAM_CODESIGN_IDENTITY}"
                    --entitlements "${CMAKE_CURRENT_SOURCE_DIR}/Entitlements.plist"
                    "$<TARGET_BUNDLE_DIR:${TARGET}>"
            COMMENT "Code signing ${TARGET}"
        )
    else()
        message(STATUS "VCam: Skipping code signing (set VCAM_CODESIGN_IDENTITY to enable)")
    endif()
endfunction()
