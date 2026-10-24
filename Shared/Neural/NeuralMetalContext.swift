import Foundation
import Metal
import MidgarCore
import TailscodeCore

#if canImport(UIKit)
    import UIKit
#endif

/// Which of the shader pairs a pipeline runs.
enum NeuralPass: Hashable, Sendable {
    /// The dome's mesh and the interior fragment, opaque.
    case interior
    /// The full quad and the front fragment, premultiplied over a transparent clear.
    case front
    /// The front fragment written over what is there with no blending, for the eye, ear and ribs
    /// drawn into the front the last full frame left behind.
    case frontReplace
    /// One texel read per pixel, the retained front copied into a drawable.
    case copy

    /// The function constants this pass reads. Every other bit is cleared before a pipeline is
    /// looked up, so a frame that differs only in what the pass ignores shares a pipeline.
    var relevantKeys: NeuralPipelineKey {
        switch self {
        case .interior: return [.ripple, .sweep, .crunch]
        case .front, .frontReplace: return [.spill, .rainbow]
        case .copy: return []
        }
    }
}

/// A pipeline looked up by what it draws, the terms it is specialised for and what it draws into.
struct NeuralPipelineRequest: Hashable, Sendable {
    let pass: NeuralPass
    let key: NeuralPipelineKey
    let format: MTLPixelFormat
}

/// The nine layers of the head as resident textures. The colour layers are the sRGB variants of
/// their container's format, so the hardware linearises them on sample; the masks and blooms are
/// data and stay linear. The two arrays are the bindings of the two passes, built once so a frame
/// allocates nothing to bind them.
struct NeuralTextureSet: @unchecked Sendable {
    let chassis: MTLTexture
    let interior: MTLTexture
    let glass: MTLTexture
    let mask0: MTLTexture
    let mask1: MTLTexture
    let mask2: MTLTexture
    let bloom0: MTLTexture
    let bloom1: MTLTexture
    let bloom2: MTLTexture
    let interiorBinding: [MTLTexture?]
    let frontBinding: [MTLTexture?]
    let residentBytes: Int

    init(
        chassis: MTLTexture, interior: MTLTexture, glass: MTLTexture, mask0: MTLTexture,
        mask1: MTLTexture, mask2: MTLTexture, bloom0: MTLTexture, bloom1: MTLTexture,
        bloom2: MTLTexture
    ) {
        self.chassis = chassis
        self.interior = interior
        self.glass = glass
        self.mask0 = mask0
        self.mask1 = mask1
        self.mask2 = mask2
        self.bloom0 = bloom0
        self.bloom1 = bloom1
        self.bloom2 = bloom2
        interiorBinding = [interior, mask0, mask1, bloom0, bloom1]
        frontBinding = [chassis, glass, mask2, bloom2]
        residentBytes = [chassis, interior, glass, mask0, mask1, mask2, bloom0, bloom1, bloom2]
            .reduce(0) { $0 + $1.allocatedSize }
    }
}

/// The Metal state the whole process shares: one device, one queue and one library for the head,
/// the presence orb and the answer's alpha renderer, the pipelines compiled from it, and the
/// head's textures while somebody holds them.
///
/// Building any of this costs milliseconds on a phone, and each view that made its own paid it on
/// the main thread when it first appeared; the process pays it once, off the main thread
/// (``warm()``), and a view that arrives afterwards finds it done. The textures are the only part
/// that costs memory, so they are loaded on a background queue when the first holder arrives
/// (``retain()``), stay while any holder remains, and are dropped with the last (``release()``) or
/// on a memory warning that finds nobody holding them.
final class NeuralMetalContext: @unchecked Sendable {
    /// The process's context, or nil on a machine with no Metal device or no compiled library.
    static let shared: NeuralMetalContext? = NeuralMetalContext()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let library: MTLLibrary
    /// Whether the head can be drawn here: the GPU takes ASTC (every Apple GPU, Apple-silicon
    /// Macs; an Intel Mac does not) and the library carries the head's shaders. A client that
    /// finds this false keeps the Lines style and the glyph.
    let isSupported: Bool
    let domeVertices: MTLBuffer?
    let domeVertexCount: Int

    private let lock = NSLock()
    private var holds = 0
    private var textures: NeuralTextureSet?
    private var loading = false
    private var loadFailed = false
    private var generation = 0
    private var waiters: [@MainActor @Sendable (Bool) -> Void] = []
    private var pipelines: [NeuralPipelineRequest: MTLRenderPipelineState] = [:]
    private var premultipliedPipelines: [PremultipliedRequest: MTLRenderPipelineState] = [:]
    private var directory: URL?
    private let loadQueue = DispatchQueue(
        label: "com.guitaripod.tailscode.neural.textures", qos: .userInitiated)
    private let compileQueue = DispatchQueue(
        label: "com.guitaripod.tailscode.neural.pipelines", qos: .utility)

    private struct PremultipliedRequest: Hashable {
        let vertex: String
        let fragment: String
        let format: MTLPixelFormat
    }

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
            let library = device.makeDefaultLibrary()
        else { return nil }
        self.device = device
        self.queue = queue
        self.library = library
        let names = Set(library.functionNames)
        isSupported =
            device.supportsFamily(.apple2) && names.contains("neuralInteriorFragment")
            && names.contains("neuralFrontFragment") && names.contains("neuralDomeVertex")
            && names.contains("neuralQuadVertex") && names.contains("neuralCopyFragment")
        let vertices = NeuralDomeMesh.vertices()
        domeVertexCount = vertices.count
        domeVertices = vertices.withUnsafeBytes {
            device.makeBuffer(
                bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }
        domeVertices?.label = "neural dome"
        observeMemoryPressure()
    }

    /// Builds the shared state and compiles the pipelines the head, the orb and the answer renderer
    /// open with, on a background queue. Called once at launch; calling it again costs nothing.
    static func warm() {
        DispatchQueue.global(qos: .utility).async {
            shared?.warmPipelines()
        }
    }

    /// The folder the container files are read from. The bundle's `ntex` folder unless a tool
    /// points elsewhere before the first holder arrives.
    func setAssetDirectory(_ url: URL?) {
        lock.lock()
        directory = url
        lock.unlock()
    }

    private func assetDirectory() -> URL? {
        lock.lock()
        let configured = directory
        lock.unlock()
        if let configured { return configured }
        return Bundle.main.resourceURL?.appendingPathComponent("ntex", isDirectory: true)
    }

    var retainCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return holds
    }

    var isResident: Bool {
        lock.lock()
        defer { lock.unlock() }
        return textures != nil
    }

    /// What the resident textures occupy on the GPU, in bytes; zero while none are resident.
    var residentBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return textures?.residentBytes ?? 0
    }

    /// The textures, or nil while they are loading, after a failed load or when nobody holds them.
    func currentTextures() -> NeuralTextureSet? {
        lock.lock()
        defer { lock.unlock() }
        return textures
    }

    /// One more holder of the textures. The first holder starts the load; a view holds the context
    /// while it is on screen and open.
    func retain() {
        lock.lock()
        holds += 1
        if textures == nil && !loading && !loadFailed { startLoadLocked() }
        lock.unlock()
    }

    /// One holder fewer. Dropping the last frees every texture and forgets a failed load, so the
    /// next holder tries again.
    func release() {
        lock.lock()
        holds = max(0, holds - 1)
        if holds == 0 { dropLocked() }
        lock.unlock()
    }

    /// Frees the textures if nobody holds them: what a memory warning does.
    func dropIfUnretained() {
        lock.lock()
        if holds == 0 { dropLocked() }
        lock.unlock()
    }

    /// Warms the pipelines and, while the context is held, loads the textures, then calls
    /// `completion` on the main actor with whether the head can be drawn now. A context nobody
    /// holds loads no textures and answers once the pipelines are ready.
    func prepare(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard isSupported else {
            Task { @MainActor in completion(false) }
            return
        }
        compileQueue.async { [self] in
            warmPipelines()
            lock.lock()
            if holds > 0 && textures == nil && !loadFailed {
                waiters.append(completion)
                if !loading { startLoadLocked() }
                lock.unlock()
                return
            }
            let ready = textures != nil || holds == 0
            lock.unlock()
            Task { @MainActor in completion(ready) }
        }
    }

    /// Loads the textures on the calling thread when the context is held and they are not
    /// resident. For tools and tests that draw once and cannot wait for a callback; a view uses
    /// ``prepare(completion:)``.
    @discardableResult
    func prepareSynchronously() -> Bool {
        guard isSupported else { return false }
        warmPipelines()
        lock.lock()
        if textures != nil {
            lock.unlock()
            return true
        }
        lock.unlock()
        guard let directory = assetDirectory(), let set = Self.load(device: device, from: directory)
        else { return false }
        lock.lock()
        defer { lock.unlock() }
        if holds > 0 && textures == nil { textures = set }
        return textures != nil
    }

    private func dropLocked() {
        let wasResident = textures != nil
        textures = nil
        loadFailed = false
        generation += 1
        let pending = waiters
        waiters = []
        if wasResident {
            MidgarLog.info("neural textures dropped", category: .performance)
        }
        if !pending.isEmpty {
            Task { @MainActor in for waiter in pending { waiter(false) } }
        }
    }

    private func startLoadLocked() {
        loading = true
        let wanted = generation
        loadQueue.async { [self] in
            let started = DispatchTime.now()
            let set = assetDirectory().flatMap { Self.load(device: device, from: $0) }
            lock.lock()
            loading = false
            var finished: [@MainActor @Sendable (Bool) -> Void] = []
            var ok = false
            if generation == wanted && holds > 0 {
                if let set {
                    textures = set
                    ok = true
                } else {
                    loadFailed = true
                }
                finished = waiters
                waiters = []
            } else if holds > 0 && textures == nil && !loadFailed {
                startLoadLocked()
            }
            lock.unlock()
            if ok {
                let ms = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6
                MidgarLog.info(
                    "neural textures resident \(set?.residentBytes ?? 0) bytes in \(Int(ms)) ms", category: .performance)
            } else if set == nil {
                MidgarLog.error("neural textures failed to load", category: .performance)
            }
            if !finished.isEmpty {
                Task { @MainActor in for waiter in finished { waiter(ok) } }
            }
        }
    }

    private func observeMemoryPressure() {
        #if canImport(UIKit)
            NotificationCenter.default.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil
            ) { [weak self] _ in
                self?.dropIfUnretained()
            }
        #else
            let source = DispatchSource.makeMemoryPressureSource(
                eventMask: [.warning, .critical], queue: .global(qos: .utility))
            source.setEventHandler { [weak self] in self?.dropIfUnretained() }
            source.resume()
            pressureSource = source
        #endif
    }

    #if !canImport(UIKit)
        private var pressureSource: DispatchSourceMemoryPressure?
    #endif
}

extension NeuralMetalContext {
    /// A pipeline of the head, compiled on first use and kept. Nil when the library lacks the
    /// functions or the descriptor is refused.
    func pipeline(
        _ pass: NeuralPass, key: NeuralPipelineKey, format: MTLPixelFormat
    ) -> MTLRenderPipelineState? {
        let request = NeuralPipelineRequest(
            pass: pass, key: key.intersection(pass.relevantKeys), format: format)
        lock.lock()
        if let hit = pipelines[request] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        guard let made = makePipeline(request) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let raced = pipelines[request] { return raced }
        pipelines[request] = made
        return made
    }

    /// A pipeline for a vertex and a fragment function by name, drawing premultiplied colour into a
    /// target of `format`: the one blend state the presence orb and the answer renderer share.
    func premultipliedPipeline(
        vertex: String, fragment: String, format: MTLPixelFormat
    ) -> MTLRenderPipelineState? {
        let request = PremultipliedRequest(vertex: vertex, fragment: fragment, format: format)
        lock.lock()
        if let hit = premultipliedPipelines[request] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        guard let vertexFunction = library.makeFunction(name: vertex),
            let fragmentFunction = library.makeFunction(name: fragment)
        else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "\(vertex)+\(fragment)"
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        Self.configure(descriptor.colorAttachments[0], format: format, blended: true)
        guard let made = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        if let raced = premultipliedPipelines[request] { return raced }
        premultipliedPipelines[request] = made
        return made
    }

    /// Compiles what the first frames of each client need, so the first paint is a cache hit: the
    /// head's common specialisations, the orb's pipeline and the answer renderer's two.
    func warmPipelines() {
        if isSupported {
            let format = NeuralHeadRenderer.pixelFormat
            for key: NeuralPipelineKey in [[], .ripple, .sweep, .crunch, [.ripple, .sweep]] {
                _ = pipeline(.interior, key: key, format: format)
            }
            for key: NeuralPipelineKey in [[], .spill, [.spill, .rainbow]] {
                _ = pipeline(.front, key: key, format: format)
                _ = pipeline(.frontReplace, key: key, format: format)
            }
            _ = pipeline(.copy, key: [], format: format)
        }
        _ = premultipliedPipeline(vertex: "orb_vertex", fragment: "orb_fragment", format: .bgra8Unorm)
        _ = premultipliedPipeline(
            vertex: "aurora_glyph_vertex", fragment: "aurora_glyph_fragment", format: .bgra8Unorm)
        _ = premultipliedPipeline(
            vertex: "aurora_nib_vertex", fragment: "aurora_nib_fragment", format: .bgra8Unorm)
    }

    private static func configure(
        _ attachment: MTLRenderPipelineColorAttachmentDescriptor?, format: MTLPixelFormat,
        blended: Bool
    ) {
        guard let attachment else { return }
        attachment.pixelFormat = format
        attachment.isBlendingEnabled = blended
        guard blended else { return }
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    }

    private func makePipeline(_ request: NeuralPipelineRequest) -> MTLRenderPipelineState? {
        let descriptor = MTLRenderPipelineDescriptor()
        let vertexName: String
        let fragmentName: String
        var blended = false
        switch request.pass {
        case .interior:
            vertexName = "neuralDomeVertex"
            fragmentName = "neuralInteriorFragment"
            descriptor.vertexDescriptor = Self.domeVertexDescriptor()
        case .front:
            vertexName = "neuralQuadVertex"
            fragmentName = "neuralFrontFragment"
            blended = true
        case .frontReplace:
            vertexName = "neuralQuadVertex"
            fragmentName = "neuralFrontFragment"
        case .copy:
            vertexName = "neuralQuadVertex"
            fragmentName = "neuralCopyFragment"
        }
        guard let vertex = library.makeFunction(name: vertexName) else { return nil }
        let fragment: MTLFunction?
        if request.pass == .copy {
            fragment = library.makeFunction(name: fragmentName)
        } else {
            fragment = try? library.makeFunction(
                name: fragmentName, constantValues: request.key.constantValues())
        }
        guard let fragment else { return nil }
        descriptor.label = "neural \(request.pass) \(request.key.rawValue)"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        Self.configure(descriptor.colorAttachments[0], format: request.format, blended: blended)
        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            MidgarLog.error(
                "neural pipeline \(request.pass) failed: \(error)", category: .performance)
            return nil
        }
    }

    private static func domeVertexDescriptor() -> MTLVertexDescriptor {
        let descriptor = MTLVertexDescriptor()
        descriptor.attributes[0].format = .float2
        descriptor.attributes[0].offset = 0
        descriptor.attributes[0].bufferIndex = 0
        descriptor.layouts[0].stride = NeuralDomeMesh.stride
        descriptor.layouts[0].stepFunction = .perVertex
        return descriptor
    }
}

extension NeuralMetalContext {
    /// The nine textures uploaded from the container files in `directory`, or nil if any is
    /// missing, malformed or in a format this GPU cannot sample. No pixel is decoded: each mip's
    /// bytes go to the texture as they are.
    static func load(device: MTLDevice, from directory: URL) -> NeuralTextureSet? {
        func texture(_ name: NeuralAssetName) -> MTLTexture? {
            let url = directory.appendingPathComponent("\(name.fileName).ntex")
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                let container = NeuralTextureContainer.decode(data)
            else {
                MidgarLog.error(
                    "neural container unreadable: \(name.fileName)", category: .performance)
                return nil
            }
            return upload(container, name: name, device: device)
        }
        guard let chassis = texture(.chassis), let interior = texture(.interior),
            let glass = texture(.glass), let mask0 = texture(.mask0), let mask1 = texture(.mask1),
            let mask2 = texture(.mask2), let bloom0 = texture(.bloom0),
            let bloom1 = texture(.bloom1), let bloom2 = texture(.bloom2)
        else { return nil }
        return NeuralTextureSet(
            chassis: chassis, interior: interior, glass: glass, mask0: mask0, mask1: mask1,
            mask2: mask2, bloom0: bloom0, bloom1: bloom1, bloom2: bloom2)
    }

    /// The Metal format for a container's storage: the colour layers sRGB, the data layers linear.
    static func pixelFormat(for format: NeuralPixelFormat, isColour: Bool) -> MTLPixelFormat {
        switch format {
        case .rgba8: return isColour ? .rgba8Unorm_srgb : .rgba8Unorm
        case .astc4x4: return isColour ? .astc_4x4_srgb : .astc_4x4_ldr
        case .astc6x6: return isColour ? .astc_6x6_srgb : .astc_6x6_ldr
        }
    }

    private static func upload(
        _ container: NeuralTextureContainer, name: NeuralAssetName, device: MTLDevice
    ) -> MTLTexture? {
        let isColour = !(name.isMask || name.isBloom)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat(for: container.format, isColour: isColour),
            width: container.width, height: container.height, mipmapped: false)
        descriptor.mipmapLevelCount = container.mipCount
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.label = "neural \(name.fileName)"
        let block = container.format.blockSize
        for (level, mip) in container.mips.enumerated() {
            let size = NeuralTextureContainer.mipSize(
                width: container.width, height: container.height, level: level)
            let across = (size.width + block.width - 1) / block.width
            let bytesPerRow = across * container.format.bytesPerBlock
            mip.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                texture.replace(
                    region: MTLRegionMake2D(0, 0, size.width, size.height), mipmapLevel: level,
                    withBytes: base, bytesPerRow: bytesPerRow)
            }
        }
        return texture
    }
}
