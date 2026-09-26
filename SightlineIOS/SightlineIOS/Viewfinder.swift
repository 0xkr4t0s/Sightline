import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Metal
import MetalKit
import Synchronization
import SwiftUI
import UIKit

/// One decoded viewfinder frame: an IOSurface-backed BGRA pixel buffer from the decoder's pool and
/// the Metal texture that aliases it (no copy). Holding the frame keeps the buffer out of the pool.
///
/// `@unchecked Sendable`: every field is immutable, and the pixels are written only before `init`
/// (by the decoder), then only read by the GPU.
nonisolated final class ViewfinderFrame: @unchecked Sendable {
    let info: VCPVideoFrameInfo
    let texture: any MTLTexture
    private let pixelBuffer: CVPixelBuffer
    private let metalTexture: CVMetalTexture

    fileprivate init(info: VCPVideoFrameInfo, texture: any MTLTexture, pixelBuffer: CVPixelBuffer,
                     metalTexture: CVMetalTexture) {
        self.info = info
        self.texture = texture
        self.pixelBuffer = pixelBuffer
        self.metalTexture = metalTexture
    }
}

/// JPEG → Metal texture with ImageIO (FR-VF-001), on its own queue so the tracking queue never
/// waits for a decode. At most one frame waits: a newer one replaces it, so frames are dropped,
/// never queued (FR-VF-002).
///
/// `@unchecked Sendable`: `device` and `textureCache` are thread-safe Metal/CoreVideo objects, and
/// all mutable state is behind the two mutexes.
nonisolated final class ViewfinderDecoder: @unchecked Sendable {
    /// Larger frames are refused before decoding; the add-on's largest resolution is far smaller.
    static let maxSide = 4096

    struct Stats: Equatable, Sendable {
        var decoded: UInt64 = 0
        /// Replaced by a newer frame before their decode started.
        var superseded: UInt64 = 0
        /// Not a decodable JPEG, too large, or no pixel buffer or texture for it.
        var failed: UInt64 = 0
    }

    private struct Slot {
        var pending: (info: VCPVideoFrameInfo, jpeg: Data)?
        var draining = false
        var stats = Stats()
    }

    private struct Pool {
        var pool: CVPixelBufferPool
        var width: Int
        var height: Int
    }

    private let slot = Mutex(Slot())
    /// Touched only on `queue`; the mutex is never contended.
    private let pool = Mutex<Pool?>(nil)
    private let queue = DispatchQueue(label: "Sightline.ViewfinderDecoder", qos: .userInteractive)
    private let textureCache: CVMetalTextureCache
    private let onFrame: @Sendable (ViewfinderFrame) -> Void
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)

    /// `onFrame` runs on the decoder's queue, once per decoded frame, in `frame_id` order.
    init?(device: any MTLDevice, onFrame: @escaping @Sendable (ViewfinderFrame) -> Void) {
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache
        else { return nil }
        textureCache = cache
        self.onFrame = onFrame
    }

    var stats: Stats { slot.withLock { $0.stats } }

    /// Hands over a complete encoded frame. Returns at once; any frame still waiting is dropped.
    func submit(_ info: VCPVideoFrameInfo, jpeg: Data) {
        let start = slot.withLock { slot in
            if slot.pending != nil { slot.stats.superseded += 1 }
            slot.pending = (info, jpeg)
            defer { slot.draining = true }
            return !slot.draining
        }
        if start {
            queue.async { self.drain() }
        }
    }

    private func drain() {
        while true {
            let next = slot.withLock { slot in
                defer { slot.pending = nil }
                if slot.pending == nil { slot.draining = false }
                return slot.pending
            }
            guard let next else { return }
            let frame = decode(next.info, next.jpeg)
            slot.withLock { slot in
                if frame == nil { slot.stats.failed += 1 } else { slot.stats.decoded += 1 }
            }
            if let frame { onFrame(frame) }
        }
    }

    private func decode(_ info: VCPVideoFrameInfo, _ jpeg: Data) -> ViewfinderFrame? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...Self.maxSide).contains(width), (1...Self.maxSide).contains(height),
              let image = CGImageSourceCreateImageAtIndex(
                  source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.width == width, image.height == height,
              let sRGB,
              let buffer = pixelBuffer(width: width, height: height)
        else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        // Row 0 of a bitmap context is the top of the image, as it is for the texture.
        let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                space: sRGB,
                                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard context != nil else { return nil }

        var metalTexture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, buffer, nil,
                                                        .bgra8Unorm, width, height, 0, &metalTexture)
                == kCVReturnSuccess,
              let metalTexture, let texture = CVMetalTextureGetTexture(metalTexture)
        else { return nil }
        return ViewfinderFrame(info: info, texture: texture, pixelBuffer: buffer, metalTexture: metalTexture)
    }

    /// A buffer from the pool for this size; a new size (the host changed resolution) replaces it.
    private func pixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        pool.withLock { current in
            if current?.width != width || current?.height != height {
                current = nil
                CVMetalTextureCacheFlush(textureCache, 0)
                let attributes: [CFString: Any] = [
                    kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey: width,
                    kCVPixelBufferHeightKey: height,
                    kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
                    kCVPixelBufferMetalCompatibilityKey: true,
                ]
                var created: CVPixelBufferPool?
                guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &created)
                        == kCVReturnSuccess,
                      let created
                else { return nil }
                current = Pool(pool: created, width: width, height: height)
            }
            guard let current else { return nil }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, current.pool, &buffer) == kCVReturnSuccess
            else { return nil }
            return buffer
        }
    }
}

/// Where the frame goes in the drawable (FR-VF-001): as large as fits, centred, aspect kept, with
/// black bars on the other axis (letterbox or pillarbox). Pixels are square.
nonisolated enum ViewfinderLayout {
    /// Half-extent of the frame's quad in normalized device coordinates; zero for an empty size.
    static func quadScale(frame: CGSize, drawable: CGSize) -> SIMD2<Float> {
        guard frame.width > 0, frame.height > 0, drawable.width > 0, drawable.height > 0 else { return .zero }
        let frameAspect = frame.width / frame.height
        let drawableAspect = drawable.width / drawable.height
        return frameAspect > drawableAspect
            ? SIMD2(1, Float(drawableAspect / frameAspect))
            : SIMD2(Float(frameAspect / drawableAspect), 1)
    }
}

/// Presents the newest decoded frame (FR-VF-002): `show` keeps only the latest one and asks the
/// view to redraw, so a frame is drawn at the next display refresh after it was decoded, and frames
/// that arrive in between replace it. The view doesn't redraw on its own.
@MainActor
final class ViewfinderRenderer: NSObject, MTKViewDelegate {
    nonisolated static let pixelFormat = MTLPixelFormat.bgra8Unorm

    nonisolated let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let pipelineState: any MTLRenderPipelineState
    private nonisolated let latest = Mutex<ViewfinderFrame?>(nil)
    private weak var view: MTKView?

    /// A centred quad whose half-extent in normalized device coordinates is `scale`
    /// (`ViewfinderLayout`), textured with the frame. Compiled once at launch: a `.metal` file
    /// would need Xcode's separately downloaded Metal toolchain on every build machine.
    nonisolated static let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct ViewfinderVertex {
            float4 position [[position]];
            float2 uv;
        };

        vertex ViewfinderVertex viewfinder_vertex(uint vid [[vertex_id]], constant float2 &scale [[buffer(0)]]) {
            // Triangle strip: bottom left, bottom right, top left, top right.
            float2 corner = float2(float(vid & 1), float(vid >> 1));
            ViewfinderVertex out;
            out.position = float4((corner * 2.0 - 1.0) * scale, 0.0, 1.0);
            // Texture row 0 is the top of the image.
            out.uv = float2(corner.x, 1.0 - corner.y);
            return out;
        }

        fragment half4 viewfinder_fragment(ViewfinderVertex in [[stage_in]], texture2d<half> frame [[texture(0)]]) {
            constexpr sampler linear(filter::linear, address::clamp_to_edge);
            return frame.sample(linear, in.uv);
        }
        """

    /// Nil without Metal.
    init?(device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()) {
        guard let device, let commandQueue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.shaderSource, options: nil)
        else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "viewfinder_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "viewfinder_fragment")
        descriptor.colorAttachments[0].pixelFormat = Self.pixelFormat
        guard descriptor.vertexFunction != nil, descriptor.fragmentFunction != nil,
              let pipelineState = try? device.makeRenderPipelineState(descriptor: descriptor)
        else { return nil }
        self.device = device
        self.commandQueue = commandQueue
        self.pipelineState = pipelineState
    }

    /// Callable from any thread (the decoder's queue).
    nonisolated func show(_ frame: ViewfinderFrame) {
        latest.withLock { $0 = frame }
        DispatchQueue.main.async { [weak self] in
            self?.view?.setNeedsDisplay()
        }
    }

    /// The newest frame handed to `show`, nil before the first.
    nonisolated var frame: ViewfinderFrame? { latest.withLock { $0 } }

    func makeView() -> MTKView {
        let view = MTKView(frame: .zero, device: device)
        view.colorPixelFormat = Self.pixelFormat
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = self
        self.view = view
        return view
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        view.setNeedsDisplay()
    }

    func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }
        encode(frame, pass: pass, drawableSize: view.drawableSize, into: commandBuffer)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Clears `pass` to black and draws `frame` letterboxed into it.
    func encode(_ frame: ViewfinderFrame?, pass: MTLRenderPassDescriptor, drawableSize: CGSize,
                into commandBuffer: any MTLCommandBuffer) {
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        if let frame {
            var scale = ViewfinderLayout.quadScale(
                frame: CGSize(width: frame.texture.width, height: frame.texture.height), drawable: drawableSize)
            encoder.setRenderPipelineState(pipelineState)
            encoder.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
            encoder.setFragmentTexture(frame.texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            // The pixel buffer must stay out of the pool until the GPU has read it.
            commandBuffer.addCompletedHandler { _ in withExtendedLifetime(frame) {} }
        }
        encoder.endEncoding()
    }
}

/// The viewfinder behind the status screen; plain black where Metal is unavailable.
struct ViewfinderView: UIViewRepresentable {
    let renderer: ViewfinderRenderer?

    func makeUIView(context: Context) -> UIView {
        if let renderer { return renderer.makeView() }
        let view = UIView()
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
