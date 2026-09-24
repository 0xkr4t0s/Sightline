// VCamReceiver - Enterprise Virtual Camera Driver
// SPDX-License-Identifier: Proprietary
// Phase 3: CMIOExtensionStreamSource — video data pipeline.

import CoreMediaIO
import CoreVideo
import Foundation

/// Video stream source for the virtual camera.
/// Pushes CMSampleBuffer frames to consuming applications (Zoom, OBS, FaceTime, etc.).
class VCamStreamSource: NSObject, CMIOExtensionStreamSource {

    private(set) var stream: CMIOExtensionStream!
    private var _isStreaming = false
    private var _activeFormatIndex: Int = 0

    // Output dimensions
    static let defaultWidth: Int32 = 1920
    static let defaultHeight: Int32 = 1080

    // Timing
    private let frameDuration30fps = CMTime(value: 1, timescale: 30)
    private let frameDuration60fps = CMTime(value: 1, timescale: 60)

    override init() {
        super.init()

        let streamID = UUID()

        stream = CMIOExtensionStream(
            localizedName: "VCam Blender Video",
            streamID: streamID,
            direction: .source,
            clockType: .hostTime,
            source: self
        )

        logger.info("Stream created: \(streamID.uuidString)")
    }

    // MARK: - Format Descriptions

    private static func createFormatDescriptions() -> [CMFormatDescription] {
        var descriptions: [CMFormatDescription] = []

        // 1920x1080 BGRA
        if let desc = createVideoFormatDescription(
            width: defaultWidth,
            height: defaultHeight,
            pixelFormat: kCVPixelFormatType_32BGRA
        ) {
            descriptions.append(desc)
        }

        // 1280x720 BGRA
        if let desc = createVideoFormatDescription(
            width: 1280,
            height: 720,
            pixelFormat: kCVPixelFormatType_32BGRA
        ) {
            descriptions.append(desc)
        }

        return descriptions
    }

    private static func createVideoFormatDescription(
        width: Int32,
        height: Int32,
        pixelFormat: OSType
    ) -> CMFormatDescription? {
        var formatDescription: CMFormatDescription?

        let extensions: [String: Any] = [
            kCMFormatDescriptionExtension_FormatName as String:
                "VCam Blender \(width)x\(height)",
        ]

        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: pixelFormat,
            width: width,
            height: height,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &formatDescription
        )

        return formatDescription
    }

    // MARK: - CMIOExtensionStreamSource

    var formats: [CMIOExtensionStreamFormat] {
        let descriptions = VCamStreamSource.createFormatDescriptions()
        return descriptions.map { desc in
            CMIOExtensionStreamFormat(
                formatDescription: desc,
                maxFrameDuration: frameDuration30fps,
                minFrameDuration: frameDuration60fps,
                validFrameDurations: nil
            )
        }
    }

    var activeFormatIndex: Int {
        return _activeFormatIndex
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [
            .streamActiveFormatIndex,
            .streamFrameDuration,
        ]
    }

    func streamProperties(
        forProperties properties: Set<CMIOExtensionProperty>
    ) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = _activeFormatIndex
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = frameDuration30fps
        }
        return streamProperties
    }

    func setStreamProperties(
        _ streamProperties: CMIOExtensionStreamProperties
    ) throws {
        if let index = streamProperties.activeFormatIndex {
            _activeFormatIndex = index
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        return true
    }

    func startStream() throws {
        _isStreaming = true
        logger.info("Stream started")
    }

    func stopStream() throws {
        _isStreaming = false
        logger.info("Stream stopped")
    }

    // MARK: - Frame Pushing

    var isStreaming: Bool {
        return _isStreaming
    }

    /// Push a CVPixelBuffer as a video frame to all connected consumers.
    func pushFrame(pixelBuffer: CVPixelBuffer, hostTimeNs: UInt64) {
        guard _isStreaming else { return }

        var sampleBuffer: CMSampleBuffer?
        var timingInfo = CMSampleTimingInfo()
        timingInfo.presentationTimeStamp = CMTime(
            value: CMTimeValue(hostTimeNs),
            timescale: 1_000_000_000
        )
        timingInfo.duration = frameDuration30fps
        timingInfo.decodeTimeStamp = .invalid

        var formatDescription: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )

        guard let desc = formatDescription else {
            logger.error("Failed to create format description from pixel buffer")
            return
        }

        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: desc,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )

        guard status == noErr, let buffer = sampleBuffer else {
            logger.error("Failed to create sample buffer: \(status)")
            return
        }

        stream.send(
            buffer,
            discontinuity: [],
            hostTimeInNanoseconds: hostTimeNs
        )
    }

    /// Push a solid color test frame (used for verifying the pipeline works).
    func pushTestFrame(red: UInt8, green: UInt8, blue: UInt8) {
        let width = Int(VCamStreamSource.defaultWidth)
        let height = Int(VCamStreamSource.defaultHeight)

        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]

        CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )

        guard let pb = pixelBuffer else { return }

        CVPixelBufferLockBaseAddress(pb, [])
        if let baseAddr = CVPixelBufferGetBaseAddress(pb) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
            let ptr = baseAddr.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * bytesPerRow + x * 4
                    ptr[offset + 0] = blue   // B
                    ptr[offset + 1] = green  // G
                    ptr[offset + 2] = red    // R
                    ptr[offset + 3] = 255    // A
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])

        let hostTime = mach_absolute_time()
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let hostTimeNs = hostTime * UInt64(info.numer) / UInt64(info.denom)

        pushFrame(pixelBuffer: pb, hostTimeNs: hostTimeNs)
    }
}
