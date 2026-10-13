import Metal
import QuartzCore
import RealityKit

/// The game's screen as a RealityKit texture, or drawn into a Metal layer (the
/// flat screen window). Each new frame from the core is copied into a shared
/// Metal buffer, run through the CRT kernels (CRT.metal) into a larger
/// linear-light texture, optionally with one mip level to soften the
/// scanlines' shimmer. In stereo both eyes are stacked in one texture, left on
/// top (twice the height), and the screen's material shows each eye its half.
@MainActor
final class ScreenTexture {
    /// Where the picture goes: a RealityKit texture (`resource`), or a layer's
    /// drawables (mono only, without mips: the layer is scaled to its view).
    enum Output {
        case texture
        case layer(CAMetalLayer)
    }

    private let output: Output
    private var texture: LowLevelTexture?
    private let textureResource: TextureResource?

    /// The picture as a RealityKit texture (made with the `.texture` output).
    var resource: TextureResource { textureResource! }

    private let queue: MTLCommandQueue
    private let crtPipeline: MTLComputePipelineState
    private let gatherPipeline: MTLComputePipelineState
    private var gpuSeq: UInt64 = 0
    /// Bloom (as vision-emulator's): soft threshold onto a grid of
    /// `bloomCell` source pixels each way, then a Gaussian blur across (into
    /// the scratch texture) and back down (into `bloomTexture`).
    private let bloomThresholdPipeline: MTLComputePipelineState
    private let bloomBlurPipeline: MTLComputePipelineState
    private var bloomTexture: MTLTexture
    private var bloomScratch: MTLTexture
    /// The frame in linear light (linearKernel), which the CRT and bloom kernels read.
    private let linearPipeline: MTLComputePipelineState
    private var linearTexture: MTLTexture

    /// The CRT pass's GPU time per frame, in milliseconds (smoothed).
    var crtMilliseconds: Double { crtTime.value }
    private let crtTime = SmoothedTime()

    private let buffers: [MTLBuffer]
    private var next = 0
    private var seq: UInt64 = 0
    private var lastBuffer: MTLBuffer?

    static let sourceWidth = 496 // the original screen

    /// The frames' width now: the original's, or wider in widescreen (only
    /// into a layer, the flat screen window; a texture keeps the original).
    private(set) var width = ScreenTexture.sourceWidth

    /// Output samples per source pixel: across, and per scanline.
    static let scale = (x: 2, y: 4)

    static let bloomCell = 2

    /// Both eyes, stacked.
    let stereo: Bool

    /// Scanlines at all (off for the start volume's little screen, and in stereo).
    let scanlines: Bool // in 3D, lines on the picture fight its depth

    /// Source rows: one screen, or two stacked.
    private var rows: Int { GameSession.screenHeight * (stereo ? 2 : 1) }

    var settings: CRTSettings {
        didSet {
            if settings.mipSmoothing != oldValue.mipSmoothing { rebuildTexture() }
            if settings != oldValue { reprocess() }
        }
    }

    static var outputSize: (width: Int, height: Int) {
        (sourceWidth * scale.x, GameSession.screenHeight * scale.y)
    }

    private struct Params {
        var srcWidth: UInt32
        var srcHeight: UInt32
        var scanlines: Float
        var blur: Float
        var minBeam: Float
        var maxBeam: Float
        var brightness: Float
        var bloom: Float
        var bloomThreshold: Float
        var bloomRadius: Float
        var eyeRows: UInt32
        var edgeBlur: Float
        var convergence: Float
        var misconvergence: Float
        var purity: Float
    }

    init(settings: CRTSettings, stereo: Bool = false, scanlines: Bool = true, output: Output = .texture) throws {
        self.output = output
        if case .layer = output { self.stereo = false } else { self.stereo = stereo }
        self.scanlines = scanlines && !self.stereo

        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let crt = library.makeFunction(name: "crtKernel"),
              let gather = library.makeFunction(name: "gatherKernel"),
              let bloomThreshold = library.makeFunction(name: "bloomThresholdKernel"),
              let bloomBlur = library.makeFunction(name: "bloomBlurKernel"),
              let linear = library.makeFunction(name: "linearKernel") else {
            throw GameError(message: "Metal is unavailable")
        }

        self.queue = queue
        crtPipeline = try device.makeComputePipelineState(function: crt)
        gatherPipeline = try device.makeComputePipelineState(function: gather)
        bloomThresholdPipeline = try device.makeComputePipelineState(function: bloomThreshold)
        bloomBlurPipeline = try device.makeComputePipelineState(function: bloomBlur)
        linearPipeline = try device.makeComputePipelineState(function: linear)

        let rows = GameSession.screenHeight * (self.stereo ? 2 : 1)
        guard let bloomTexture = Self.makeBloom(device: device, width: Self.sourceWidth, rows: rows),
              let bloomScratch = Self.makeBloom(device: device, width: Self.sourceWidth, rows: rows),
              let linearTexture = Self.makeWork(device: device, width: Self.sourceWidth, height: rows) else {
            throw GameError(message: "Cannot make the CRT's textures")
        }
        self.bloomTexture = bloomTexture
        self.bloomScratch = bloomScratch
        self.linearTexture = linearTexture

        self.settings = settings
        switch output {
        case .texture:
            let texture = try Self.makeTexture(mipSmoothing: settings.mipSmoothing, stereo: self.stereo)
            self.texture = texture
            textureResource = try TextureResource(from: texture)
        case .layer(let layer):
            layer.device = device
            layer.pixelFormat = .rgba16Float // linear light, as the kernels write it
            layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
            layer.framebufferOnly = false // the CRT kernel writes it
            layer.drawableSize = CGSize(width: Self.outputSize.width, height: Self.outputSize.height)
            texture = nil
            textureResource = nil
        }
        buffers = (0..<3).compactMap { _ in
            device.makeBuffer(length: GameSession.maxFrameBytes, options: .storageModeShared)
        }
    }

    private static func makeBloom(device: MTLDevice, width: Int, rows: Int) -> MTLTexture? {
        makeWork(device: device, width: width / bloomCell, height: rows / bloomCell)
    }

    /// A GPU-only texture the kernels write and read.
    private static func makeWork(device: MTLDevice, width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }

    /// Frames `width` wide from now on (widescreen changed), if this output takes them.
    private func accept(width: Int) -> Bool {
        if width == self.width { return true }
        guard case .layer(let layer) = output,
              let bloom = Self.makeBloom(device: bloomTexture.device, width: width, rows: rows),
              let scratch = Self.makeBloom(device: bloomTexture.device, width: width, rows: rows),
              let linear = Self.makeWork(device: bloomTexture.device, width: width, height: rows) else { return false }

        self.width = width
        bloomTexture = bloom
        bloomScratch = scratch
        linearTexture = linear
        layer.drawableSize = CGSize(width: width * Self.scale.x, height: rows * Self.scale.y)
        return true
    }

    private static func makeTexture(mipSmoothing: Bool, stereo: Bool) throws -> LowLevelTexture {
        let size = outputSize
        let descriptor = LowLevelTexture.Descriptor(pixelFormat: .rgba16Float, width: size.width,
                                                    height: size.height * (stereo ? 2 : 1),
                                                    mipmapLevelCount: mipSmoothing ? 2 : 1,
                                                    textureUsage: [.shaderRead, .shaderWrite, .renderTarget])
        return try LowLevelTexture(descriptor: descriptor)
    }

    private func rebuildTexture() {
        guard let textureResource,
              let fresh = try? Self.makeTexture(mipSmoothing: settings.mipSmoothing, stereo: stereo) else { return }

        texture = fresh
        textureResource.replace(with: fresh)
    }

    /// Processes the game's newest frame, if there is one.
    func update(from session: GameSession) {
        let buffer = buffers[next]
        if let frame = session.gpuFrame(seq: &gpuSeq) {
            guard frame.scale > 0, frame.width % frame.scale == 0, accept(width: frame.width / frame.scale) else { return }
            gather(frame, into: buffer)
            next = (next + 1) % buffers.count
            lastBuffer = buffer
            process(buffer)
            return
        }

        var width = 0, height = 0
        guard session.copyFrame(into: buffer.contents(), capacity: buffer.length, seq: &seq,
                                width: &width, height: &height),
              accept(width: width) else { return }

        // A mono frame for a stereo screen: the same picture for both eyes.
        // (A stereo frame for a mono screen: its top half, the left eye, is all it reads.)
        let screenBytes = width * GameSession.screenHeight * 4
        if stereo, height == GameSession.screenHeight {
            buffer.contents().advanced(by: screenBytes).copyMemory(from: buffer.contents(), byteCount: screenBytes)
        }

        next = (next + 1) % buffers.count
        lastBuffer = buffer
        process(buffer)
    }

    /// A GPU-drawn frame (at its scale, one or two pictures) into `buffer` at
    /// the original size, as this screen wants it (gatherKernel).
    private func gather(_ frame: GameSession.GPUFrame, into buffer: MTLBuffer) {
        guard frame.width == width * frame.scale,
              let commands = queue.makeCommandBuffer(),
              let compute = commands.makeComputeCommandEncoder() else { return }

        struct GatherParams {
            var srcWidth: UInt32
            var scale: UInt32
            var srcEyes: UInt32
            var eyeRows: UInt32
        }
        let eyeRows = GameSession.screenHeight
        var params = GatherParams(srcWidth: UInt32(frame.pitch), scale: UInt32(frame.scale),
                                  srcEyes: UInt32(frame.height / (eyeRows * frame.scale)), eyeRows: UInt32(eyeRows))
        compute.setComputePipelineState(gatherPipeline)
        compute.setBuffer(frame.buffer, offset: 0, index: 0)
        compute.setBytes(&params, length: MemoryLayout<GatherParams>.stride, index: 1)
        compute.setBuffer(buffer, offset: 0, index: 2)
        compute.dispatchThreads(MTLSize(width: width, height: rows, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        compute.endEncoding()
        commands.commit() // the same queue as process(): done before it reads
    }

    /// Re-runs the shader on the last frame, so changes show while paused.
    private func reprocess() {
        if let lastBuffer { process(lastBuffer) }
    }

    private func process(_ buffer: MTLBuffer) {
        guard let commands = queue.makeCommandBuffer(),
              let compute = commands.makeComputeCommandEncoder() else { return }

        let s = settings
        let on = s.enabled && !stereo // no CRT effect in 3D: the eyes' pictures must match exactly
        var params = Params(srcWidth: UInt32(width), srcHeight: UInt32(rows),
                            scanlines: on && scanlines ? s.scanlines : 0, blur: on ? s.blur : 0,
                            minBeam: s.minBeam, maxBeam: max(s.minBeam, s.maxBeam),
                            brightness: on ? s.brightness : 1, bloom: on ? s.bloom : 0,
                            bloomThreshold: s.bloomThreshold, bloomRadius: s.bloomRadius,
                            eyeRows: UInt32(GameSession.screenHeight),
                            edgeBlur: on ? s.edgeBlur : 0, convergence: on ? s.convergence : 0,
                            misconvergence: on ? s.misconvergence : 0, purity: on ? s.purity : 0)

        let target: MTLTexture
        var drawable: CAMetalDrawable?
        switch output {
        case .texture:
            guard let texture else { compute.endEncoding(); return }
            target = texture.replace(using: commands)
        case .layer(let layer):
            guard let next = layer.nextDrawable() else { compute.endEncoding(); return }
            drawable = next
            target = next.texture
        }
        let group = MTLSize(width: 16, height: 16, depth: 1)
        compute.setBuffer(buffer, offset: 0, index: 0)
        compute.setBytes(&params, length: MemoryLayout<Params>.stride, index: 1)

        compute.setComputePipelineState(linearPipeline)
        compute.setTexture(linearTexture, index: 0)
        compute.dispatchThreads(MTLSize(width: width, height: rows, depth: 1), threadsPerThreadgroup: group)
        compute.setTexture(linearTexture, index: 2)

        if params.bloom > 0 {
            let grid = MTLSize(width: bloomTexture.width, height: bloomTexture.height, depth: 1)
            compute.setComputePipelineState(bloomThresholdPipeline)
            compute.setTexture(bloomTexture, index: 0)
            compute.dispatchThreads(grid, threadsPerThreadgroup: group)

            compute.setComputePipelineState(bloomBlurPipeline)
            for (direction, from, into) in [(SIMD2<Float>(1, 0), bloomTexture, bloomScratch),
                                            (SIMD2<Float>(0, 1), bloomScratch, bloomTexture)] {
                var blur = direction
                compute.setBytes(&blur, length: MemoryLayout<SIMD2<Float>>.stride, index: 3)
                compute.setTexture(into, index: 0)
                compute.setTexture(from, index: 1)
                compute.dispatchThreads(grid, threadsPerThreadgroup: group)
            }
        }

        compute.setComputePipelineState(crtPipeline)
        compute.setTexture(target, index: 0)
        compute.setTexture(bloomTexture, index: 1)
        compute.dispatchThreads(MTLSize(width: target.width, height: target.height, depth: 1),
                                threadsPerThreadgroup: group)
        compute.endEncoding()

        if target.mipmapLevelCount > 1, let blit = commands.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: target)
            blit.endEncoding()
        }

        if let drawable { commands.present(drawable) }
        commands.addCompletedHandler { [crtTime] done in
            crtTime.add((done.gpuEndTime - done.gpuStartTime) * 1000)
        }
        commands.commit()
    }
}

/// A time (milliseconds) smoothed over frames, written from Metal's completion
/// handlers and read on the main actor.
private final class SmoothedTime: @unchecked Sendable {
    private let lock = NSLock()
    private var smoothed: Double = 0

    var value: Double { lock.withLock { smoothed } }

    func add(_ ms: Double) { lock.withLock { smoothed = smoothed * 0.95 + ms * 0.05 } }
}
