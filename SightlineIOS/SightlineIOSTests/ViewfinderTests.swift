import CoreGraphics
import Foundation
import ImageIO
import Metal
import Synchronization
import UniformTypeIdentifiers
import XCTest

/// The viewfinder (task 2.3c; FR-VF-001/002): completed JPEG frames are decoded off the tracking
/// queue, only the newest waiting frame is decoded, and it is drawn letterboxed.
final class ViewfinderTests: XCTestCase {
    private static let red: [UInt8] = [255, 0, 0]
    private static let blue: [UInt8] = [0, 0, 255]

    /// A `width`×`height` JPEG whose top half is red and bottom half blue.
    private func jpeg(width: Int, height: Int) throws -> Data {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let colour = y < height / 2 ? Self.red : Self.blue
            for x in 0..<width {
                rgba.replaceSubrange((y * width + x) * 4..<(y * width + x) * 4 + 3, with: colour)
            }
        }
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let image = try rgba.withUnsafeMutableBytes { bytes in
            try XCTUnwrap(CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: space,
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage())
        }
        let out = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return out as Data
    }

    private func info(_ id: UInt32) -> VCPVideoFrameInfo {
        VCPVideoFrameInfo(frameID: id, renderTimeNs: 1_000 * UInt64(id), poseSeq: id + 100, quality: 90)
    }

    /// BGRA bytes of a shared-storage or IOSurface texture.
    private func pixels(_ texture: any MTLTexture) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        texture.getBytes(&bytes, bytesPerRow: texture.width * 4,
                         from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        return bytes
    }

    /// RGB at (x, y) of BGRA `bytes`, within JPEG tolerance of `expected`.
    private func assertColour(_ bytes: [UInt8], width: Int, _ x: Int, _ y: Int, _ expected: [UInt8],
                              _ message: String, line: UInt = #line) {
        let i = (y * width + x) * 4
        let rgb = [bytes[i + 2], bytes[i + 1], bytes[i]]
        let close = zip(rgb, expected).allSatisfy { abs(Int($0) - Int($1)) <= 24 }
        XCTAssertTrue(close, "\(message): (\(x), \(y)) is \(rgb), expected \(expected)", line: line)
    }

    private final class Frames: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [ViewfinderFrame] = []
        private var threads: [Bool] = []

        func add(_ frame: ViewfinderFrame) {
            lock.withLock {
                items.append(frame)
                threads.append(Thread.isMainThread)
            }
        }

        var all: [ViewfinderFrame] { lock.withLock { items } }
        var anyOnMain: Bool { lock.withLock { threads.contains(true) } }
    }

    private func device() throws -> any MTLDevice {
        try XCTUnwrap(MTLCreateSystemDefaultDevice(), "Metal is available in the simulator")
    }

    private func wait(for count: Int, in frames: Frames) {
        let deadline = Date(timeIntervalSinceNow: 5)
        while frames.all.count < count, Date() < deadline { usleep(1_000) }
    }

    func testJPEGIsDecodedUprightIntoATextureOffTheMainThread() throws {
        let frames = Frames()
        let decoder = try XCTUnwrap(ViewfinderDecoder(device: device()) { frames.add($0) })
        decoder.submit(info(7), jpeg: try jpeg(width: 64, height: 32))
        wait(for: 1, in: frames)

        let frame = try XCTUnwrap(frames.all.first)
        XCTAssertEqual(frame.info, info(7), "the frame's fields travel with its pixels")
        XCTAssertEqual([frame.texture.width, frame.texture.height], [64, 32])
        XCTAssertEqual(frame.texture.pixelFormat, .bgra8Unorm)
        let bytes = pixels(frame.texture)
        assertColour(bytes, width: 64, 32, 4, Self.red, "row 0 is the top of the image")
        assertColour(bytes, width: 64, 32, 27, Self.blue, "the bottom stays at the bottom")
        XCTAssertFalse(frames.anyOnMain)
        XCTAssertEqual(decoder.stats, ViewfinderDecoder.Stats(decoded: 1, superseded: 0, failed: 0))
    }

    func testOnlyTheNewestWaitingFrameIsDecoded() throws {
        let frames = Frames()
        let release = DispatchSemaphore(value: 0)
        let decoder = try XCTUnwrap(ViewfinderDecoder(device: device()) { frame in
            frames.add(frame)
            if frame.info.frameID == 1 { release.wait() }  // hold the decoder busy after frame 1
        })
        let image = try jpeg(width: 16, height: 16)
        decoder.submit(info(1), jpeg: image)
        wait(for: 1, in: frames)
        for id in UInt32(2)...4 { decoder.submit(info(id), jpeg: image) }
        release.signal()
        wait(for: 2, in: frames)
        usleep(100_000)  // a queued frame would arrive now

        XCTAssertEqual(frames.all.map(\.info.frameID), [1, 4], "frames 2 and 3 were replaced while waiting")
        XCTAssertEqual(decoder.stats, ViewfinderDecoder.Stats(decoded: 2, superseded: 2, failed: 0))
    }

    func testUndecodableAndOversizedFramesAreSkippedAndTheNextOneShows() throws {
        let frames = Frames()
        let decoder = try XCTUnwrap(ViewfinderDecoder(device: device()) { frames.add($0) })
        let bad = [Data("not a jpeg".utf8), Data([0xFF, 0xD8, 0xFF, 0xD9]),  // SOI + EOI, no image
                   try jpeg(width: ViewfinderDecoder.maxSide + 1, height: 8)]
        for (i, data) in bad.enumerated() {
            decoder.submit(info(UInt32(i + 1)), jpeg: data)
            let deadline = Date(timeIntervalSinceNow: 5)
            while decoder.stats.failed <= i, Date() < deadline { usleep(1_000) }
        }
        decoder.submit(info(4), jpeg: try jpeg(width: 16, height: 16))
        wait(for: 1, in: frames)

        XCTAssertEqual(frames.all.map(\.info.frameID), [4], "a failed frame shows nothing and blocks nothing")
        XCTAssertEqual(decoder.stats, ViewfinderDecoder.Stats(decoded: 1, superseded: 0, failed: 3))
    }

    func testFrameIsFittedInsideTheDrawableWithBars() {
        func scale(_ fw: Double, _ fh: Double, _ dw: Double, _ dh: Double) -> SIMD2<Float> {
            ViewfinderLayout.quadScale(frame: CGSize(width: fw, height: fh), drawable: CGSize(width: dw, height: dh))
        }
        XCTAssertEqual(scale(1920, 1080, 2556, 1179), SIMD2(Float((16.0 / 9) / (2556.0 / 1179)), 1),
                       "16:9 on a wider phone screen: bars left and right")
        XCTAssertEqual(scale(960, 540, 2048, 1536), SIMD2(1, Float((2048.0 / 1536) / (16.0 / 9))),
                       "16:9 on a 4:3 iPad: bars top and bottom")
        XCTAssertEqual(scale(960, 540, 1920, 1080), SIMD2(1, 1), "same aspect: fills the drawable")
        XCTAssertEqual(scale(0, 540, 1920, 1080), .zero)
        XCTAssertEqual(scale(960, 540, 1920, 0), .zero)
    }

    /// The newest frame is drawn centred, aspect kept, black elsewhere (GPU readback).
    @MainActor
    func testRendererDrawsTheFrameLetterboxedOnBlack() throws {
        let device = try device()
        let renderer = try XCTUnwrap(ViewfinderRenderer(device: device))
        let frames = Frames()
        let decoder = try XCTUnwrap(ViewfinderDecoder(device: device) { frames.add($0) })
        decoder.submit(info(1), jpeg: try jpeg(width: 32, height: 32))
        wait(for: 1, in: frames)
        renderer.show(try XCTUnwrap(frames.all.first))
        XCTAssertEqual(renderer.frame?.info.frameID, 1)

        func render(_ frame: ViewfinderFrame?, width: Int, height: Int) throws -> [UInt8] {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: ViewfinderRenderer.pixelFormat, width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget]
            descriptor.storageMode = .shared
            let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].storeAction = .store
            let commandBuffer = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
            renderer.encode(frame, pass: pass, drawableSize: CGSize(width: width, height: height),
                            into: commandBuffer)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            return pixels(target)
        }

        // A square frame on a 2:1 drawable: pillarbox, image in x 32..<96.
        var bytes = try render(renderer.frame, width: 128, height: 64)
        assertColour(bytes, width: 128, 8, 32, [0, 0, 0], "left bar")
        assertColour(bytes, width: 128, 28, 32, [0, 0, 0], "left bar up to the image")
        assertColour(bytes, width: 128, 120, 32, [0, 0, 0], "right bar")
        assertColour(bytes, width: 128, 36, 8, Self.red, "image top, near its left edge")
        assertColour(bytes, width: 128, 92, 56, Self.blue, "image bottom, near its right edge")

        // The same frame on a 1:2 drawable: letterbox, image in y 32..<96.
        bytes = try render(renderer.frame, width: 64, height: 128)
        assertColour(bytes, width: 64, 32, 8, [0, 0, 0], "top bar")
        assertColour(bytes, width: 64, 32, 120, [0, 0, 0], "bottom bar")
        assertColour(bytes, width: 64, 32, 36, Self.red, "image top")
        assertColour(bytes, width: 64, 32, 92, Self.blue, "image bottom")

        // Before any frame: black.
        bytes = try render(nil, width: 8, height: 8)
        XCTAssertTrue(stride(from: 0, to: bytes.count, by: 4).allSatisfy { bytes[$0..<$0 + 3].allSatisfy { $0 == 0 } },
                      "no frame yet: black")
    }
}
