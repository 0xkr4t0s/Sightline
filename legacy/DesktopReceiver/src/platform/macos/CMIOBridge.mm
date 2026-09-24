// VCamReceiver - Enterprise Virtual Camera Driver
// SPDX-License-Identifier: Proprietary
// ObjC++ bridge: C++ FrameBuffer → CVPixelBuffer → CMSampleBuffer.

#import "CMIOBridge.h"

#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

extern "C" {

void* vcam_bridge_create_pixel_buffer(
    const void* pixel_data,
    uint32_t width,
    uint32_t height,
    uint32_t bytes_per_row)
{
    if (!pixel_data || width == 0 || height == 0) {
        return nullptr;
    }

    CVPixelBufferRef pixelBuffer = NULL;

    // Create with IOSurface backing for CMIO compatibility
    NSDictionary* attrs = @{
        (__bridge NSString*)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };

    CVReturn status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        (__bridge CFDictionaryRef)attrs,
        &pixelBuffer
    );

    if (status != kCVReturnSuccess || !pixelBuffer) {
        return nullptr;
    }

    // Copy pixel data into the CVPixelBuffer
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    void* baseAddr = CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t destBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);

    if (baseAddr) {
        const uint8_t* src = static_cast<const uint8_t*>(pixel_data);
        uint8_t* dst = static_cast<uint8_t*>(baseAddr);

        // Copy row by row (source and dest strides may differ)
        size_t copyBytes = (bytes_per_row < destBytesPerRow) ? bytes_per_row : destBytesPerRow;
        for (uint32_t y = 0; y < height; ++y) {
            memcpy(dst + y * destBytesPerRow, src + y * bytes_per_row, copyBytes);
        }
    }

    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    return pixelBuffer;
}

void* vcam_bridge_create_sample_buffer(
    void* pixel_buffer,
    uint64_t timestamp_ns)
{
    CVPixelBufferRef pixelBuffer = static_cast<CVPixelBufferRef>(pixel_buffer);
    if (!pixelBuffer) {
        return nullptr;
    }

    CMFormatDescriptionRef formatDesc = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(
        kCFAllocatorDefault,
        pixelBuffer,
        &formatDesc
    );

    if (!formatDesc) {
        return nullptr;
    }

    CMSampleTimingInfo timingInfo;
    timingInfo.presentationTimeStamp = CMTimeMake(
        static_cast<int64_t>(timestamp_ns),
        1000000000  // nanosecond timescale
    );
    timingInfo.duration = CMTimeMake(1, 30);  // 30fps default
    timingInfo.decodeTimeStamp = kCMTimeInvalid;

    CMSampleBufferRef sampleBuffer = NULL;
    OSStatus status = CMSampleBufferCreateReadyWithImageBuffer(
        kCFAllocatorDefault,
        pixelBuffer,
        formatDesc,
        &timingInfo,
        &sampleBuffer
    );

    CFRelease(formatDesc);

    if (status != noErr || !sampleBuffer) {
        return nullptr;
    }

    return sampleBuffer;
}

void* vcam_bridge_create_test_frame(
    uint32_t width,
    uint32_t height,
    uint8_t red,
    uint8_t green,
    uint8_t blue)
{
    CVPixelBufferRef pixelBuffer = NULL;

    NSDictionary* attrs = @{
        (__bridge NSString*)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };

    CVReturn status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        (__bridge CFDictionaryRef)attrs,
        &pixelBuffer
    );

    if (status != kCVReturnSuccess || !pixelBuffer) {
        return nullptr;
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    uint8_t* baseAddr = static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(pixelBuffer));
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);

    if (baseAddr) {
        for (uint32_t y = 0; y < height; ++y) {
            uint8_t* row = baseAddr + y * bytesPerRow;
            for (uint32_t x = 0; x < width; ++x) {
                row[x * 4 + 0] = blue;   // B
                row[x * 4 + 1] = green;  // G
                row[x * 4 + 2] = red;    // R
                row[x * 4 + 3] = 255;    // A
            }
        }
    }

    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    return pixelBuffer;
}

} // extern "C"
