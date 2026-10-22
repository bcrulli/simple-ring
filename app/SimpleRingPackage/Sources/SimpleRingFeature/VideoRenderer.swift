import SwiftUI
import MetalKit
import CoreVideo
@preconcurrency import WebRTC

// MARK: - WebRTC Video View

struct WebRTCVideoView: NSViewRepresentable {
    let videoTrack: RTCVideoTrack
    let isPortrait: Bool

    func makeNSView(context: Context) -> MetalVideoView {
        let view = MetalVideoView(isPortrait: isPortrait)
        context.coordinator.attach(view: view, track: videoTrack)
        return view
    }

    func updateNSView(_ nsView: MetalVideoView, context: Context) {
        context.coordinator.attach(view: nsView, track: videoTrack)
    }

    static func dismantleNSView(_ nsView: MetalVideoView, coordinator: FrameRenderer) {
        coordinator.detach()
    }

    func makeCoordinator() -> FrameRenderer {
        FrameRenderer()
    }
}

// MARK: - Frame Renderer

/// Receives frames on WebRTC's thread and renders only the newest one on the
/// main thread, so a busy main thread drops frames instead of queueing them.
final class FrameRenderer: NSObject, RTCVideoRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var pendingFrame: RTCVideoFrame?
    private var renderScheduled = false

    // Main thread only
    private weak var view: MetalVideoView?
    private var track: RTCVideoTrack?

    @MainActor
    func attach(view: MetalVideoView, track: RTCVideoTrack) {
        self.view = view
        guard self.track !== track else { return }
        self.track?.remove(self)
        track.isEnabled = true
        track.add(self)
        self.track = track
    }

    @MainActor
    func detach() {
        track?.remove(self)
        track = nil
        view = nil
    }

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        lock.lock()
        pendingFrame = frame
        let shouldSchedule = !renderScheduled
        renderScheduled = true
        lock.unlock()

        guard shouldSchedule else { return }
        DispatchQueue.main.async {
            self.lock.lock()
            let next = self.pendingFrame
            self.pendingFrame = nil
            self.renderScheduled = false
            self.lock.unlock()

            MainActor.assumeIsolated {
                if let next { self.view?.render(next) }
            }
        }
    }
}

// MARK: - Metal Video View

/// Draws NV12 / BGRA WebRTC frames with Metal, aspect-fit inside the view.
/// Doorbells (portrait) are cropped to 9:16 from their wide/square stream.
@MainActor
final class MetalVideoView: NSView {
    private struct VertexUniforms {
        var scale: SIMD2<Float>
        var texMin: SIMD2<Float>
        var texMax: SIMD2<Float>
    }

    private struct ColorUniforms {
        var videoRange: Float
        var bt709: Float
    }

    private static let device = MTLCreateSystemDefaultDevice()
    private static let commandQueue = device?.makeCommandQueue()
    private static let pipelines = makePipelines()

    private let metalLayer = CAMetalLayer()
    private var textureCache: CVMetalTextureCache?
    private let isPortrait: Bool

    init(isPortrait: Bool) {
        self.isPortrait = isPortrait
        super.init(frame: .zero)
        wantsLayer = true
        metalLayer.device = Self.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = NSColor.black.cgColor
        layer = metalLayer
        if let device = Self.device {
            CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.frame = bounds
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    func render(_ frame: RTCVideoFrame) {
        guard let pipelines = Self.pipelines,
              let commandQueue = Self.commandQueue,
              let buffer = frame.buffer as? RTCCVPixelBuffer,
              bounds.width > 0, bounds.height > 0 else { return }

        let pixelBuffer = buffer.pixelBuffer
        let pipeline: MTLRenderPipelineState
        var textures: [(MTLTexture, CVMetalTexture)] = []
        var colors = ColorUniforms(videoRange: 0, bt709: 0)

        switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            guard let y = makeTexture(pixelBuffer, plane: 0, format: .r8Unorm),
                  let uv = makeTexture(pixelBuffer, plane: 1, format: .rg8Unorm) else { return }
            textures = [y, uv]
            pipeline = pipelines.nv12
            colors.videoRange = CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? 1 : 0
            let matrix = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil) as? String
            colors.bt709 = matrix == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String) ? 0 : 1
        case kCVPixelFormatType_32BGRA:
            guard let bgra = makeTexture(pixelBuffer, plane: nil, format: .bgra8Unorm) else { return }
            textures = [bgra]
            pipeline = pipelines.bgra
        default:
            return
        }

        guard let drawable = metalLayer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var vertex = vertexUniforms(
            sourceWidth: CGFloat(CVPixelBufferGetWidth(pixelBuffer)),
            sourceHeight: CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        )
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&vertex, length: MemoryLayout<VertexUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&colors, length: MemoryLayout<ColorUniforms>.stride, index: 0)
        for (index, texture) in textures.enumerated() {
            encoder.setFragmentTexture(texture.0, index: index)
        }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        // The CVMetalTextures must outlive the GPU work that samples them
        nonisolated(unsafe) let keepAlive = textures.map(\.1)
        commandBuffer.addCompletedHandler { _ in _ = keepAlive }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func vertexUniforms(sourceWidth: CGFloat, sourceHeight: CGFloat) -> VertexUniforms {
        // Crop portrait devices to 9:16 when the stream is wider than that
        var cropWidth: CGFloat = 1
        if isPortrait, sourceWidth / sourceHeight > 9.0 / 16.0 {
            cropWidth = (sourceHeight * 9 / 16) / sourceWidth
        }
        let xMin = Float((1 - cropWidth) / 2)

        // Aspect-fit the (cropped) content inside the view
        let contentAspect = (sourceWidth * cropWidth) / sourceHeight
        let viewAspect = bounds.width / bounds.height
        let scale: SIMD2<Float> = contentAspect > viewAspect
            ? SIMD2(1, Float(viewAspect / contentAspect))
            : SIMD2(Float(contentAspect / viewAspect), 1)

        return VertexUniforms(scale: scale, texMin: SIMD2(xMin, 0), texMax: SIMD2(1 - xMin, 1))
    }

    private func makeTexture(_ pixelBuffer: CVPixelBuffer, plane: Int?, format: MTLPixelFormat) -> (MTLTexture, CVMetalTexture)? {
        guard let textureCache else { return nil }
        let width = plane.map { CVPixelBufferGetWidthOfPlane(pixelBuffer, $0) } ?? CVPixelBufferGetWidth(pixelBuffer)
        let height = plane.map { CVPixelBufferGetHeightOfPlane(pixelBuffer, $0) } ?? CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pixelBuffer, nil, format, width, height, plane ?? 0, &cvTexture
        ) == kCVReturnSuccess,
              let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else { return nil }
        return (texture, cvTexture)
    }

    private static func makePipelines() -> (nv12: MTLRenderPipelineState, bgra: MTLRenderPipelineState)? {
        guard let device else { return nil }
        let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexUniforms { float2 scale; float2 texMin; float2 texMax; };
        struct ColorUniforms { float videoRange; float bt709; };
        struct VertexOut { float4 position [[position]]; float2 texCoord; };

        vertex VertexOut videoVertex(uint vid [[vertex_id]], constant VertexUniforms &u [[buffer(0)]]) {
            float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
            float2 uv[4] = { float2(0, 1), float2(1, 1), float2(0, 0), float2(1, 0) };
            VertexOut out;
            out.position = float4(corners[vid] * u.scale, 0, 1);
            out.texCoord = mix(u.texMin, u.texMax, uv[vid]);
            return out;
        }

        fragment float4 nv12Fragment(VertexOut in [[stage_in]],
                                     constant ColorUniforms &c [[buffer(0)]],
                                     texture2d<float> yTex [[texture(0)]],
                                     texture2d<float> uvTex [[texture(1)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            float y = yTex.sample(s, in.texCoord).r;
            float2 cbcr = uvTex.sample(s, in.texCoord).rg - 0.5;
            if (c.videoRange > 0.5) {
                y = (y - 16.0 / 255.0) * (255.0 / 219.0);
                cbcr *= 255.0 / 224.0;
            }
            float3 rgb = c.bt709 > 0.5
                ? float3(y + 1.5748 * cbcr.y, y - 0.1873 * cbcr.x - 0.4681 * cbcr.y, y + 1.8556 * cbcr.x)
                : float3(y + 1.402 * cbcr.y, y - 0.344 * cbcr.x - 0.714 * cbcr.y, y + 1.772 * cbcr.x);
            return float4(saturate(rgb), 1);
        }

        fragment float4 bgraFragment(VertexOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            return tex.sample(s, in.texCoord);
        }
        """
        do {
            let library = try device.makeLibrary(source: source, options: nil)
            func pipeline(_ fragment: String) throws -> MTLRenderPipelineState {
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "videoVertex")
                descriptor.fragmentFunction = library.makeFunction(name: fragment)
                descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
                return try device.makeRenderPipelineState(descriptor: descriptor)
            }
            return (try pipeline("nv12Fragment"), try pipeline("bgraFragment"))
        } catch {
            NSLog("📹 Failed to create Metal pipelines: \(error)")
            return nil
        }
    }
}
