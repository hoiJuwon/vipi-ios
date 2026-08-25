import MetalKit
import QuartzCore
import SwiftUI

/// Compact Ice Blue loading orb adapted from LerSent001/orb (MIT).
struct LiquidOrbView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        LiquidOrbSurface(isPaused: reduceMotion)
            .accessibilityHidden(true)
    }
}

private enum LiquidOrbError: Error {
    case metalUnavailable
    case shaderSourceUnavailable
    case shaderFunctionMissing(String)
    case commandQueueUnavailable
}

@MainActor
private final class LiquidOrbRenderer: NSObject, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let startedAt = CACurrentMediaTime()
    private var uniforms = IceBlueOrbUniforms.values

    init(view: MTKView) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw LiquidOrbError.metalUnavailable
        }
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 30
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.isOpaque = false
        view.backgroundColor = .clear
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        pipeline = try LiquidOrbPipelineCache.pipeline(device: device, pixelFormat: view.colorPixelFormat)
        guard let queue = device.makeCommandQueue() else {
            throw LiquidOrbError.commandQueueUnavailable
        }
        commandQueue = queue
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard
            view.drawableSize.width > 0,
            view.drawableSize.height > 0,
            let descriptor = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable,
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        uniforms[0] = Float(view.drawableSize.width)
        uniforms[1] = Float(view.drawableSize.height)
        uniforms[2] = Float(CACurrentMediaTime() - startedAt)
        encoder.setRenderPipelineState(pipeline)
        uniforms.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress else { return }
            encoder.setFragmentBytes(address, length: bytes.count, index: 0)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

@MainActor
private enum LiquidOrbPipelineCache {
    private static var cached: MTLRenderPipelineState?

    static func pipeline(device: MTLDevice, pixelFormat: MTLPixelFormat) throws -> MTLRenderPipelineState {
        if let cached { return cached }
        guard
            let sourceURL = Bundle.main.url(forResource: "LiquidOrb", withExtension: "metal.txt"),
            let source = try? String(contentsOf: sourceURL, encoding: .utf8)
        else {
            throw LiquidOrbError.shaderSourceUnavailable
        }
        let library = try device.makeLibrary(source: source, options: nil)
        guard let vertex = library.makeFunction(name: "vs_main") else {
            throw LiquidOrbError.shaderFunctionMissing("vs_main")
        }
        guard let fragment = library.makeFunction(name: "fs_main") else {
            throw LiquidOrbError.shaderFunctionMissing("fs_main")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        cached = pipeline
        return pipeline
    }
}

@MainActor
private final class LiquidOrbCoordinator {
    private var renderer: LiquidOrbRenderer?

    func makeView() -> MTKView {
        let view = MTKView(frame: .zero, device: nil)
        do {
            let renderer = try LiquidOrbRenderer(view: view)
            self.renderer = renderer
            view.delegate = renderer
        } catch {
            view.backgroundColor = .clear
        }
        return view
    }
}

private struct LiquidOrbSurface: UIViewRepresentable {
    let isPaused: Bool

    func makeCoordinator() -> LiquidOrbCoordinator { LiquidOrbCoordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = context.coordinator.makeView()
        configurePlayback(of: view)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        configurePlayback(of: view)
    }

    private func configurePlayback(of view: MTKView) {
        view.enableSetNeedsDisplay = isPaused
        view.isPaused = isPaused
        if isPaused { view.setNeedsDisplay() }
    }
}

private enum IceBlueOrbUniforms {
    static var values: [Float] {
        var values = Array(repeating: Float.zero, count: 128)
        values.replaceSubrange(3...31, with: [
            0.82, 0.72, 0.36, 3.2, 0.5, 2.2, 0.12, 0.28, 0.24,
            0.18, 0.18, 1.45, 9, 0.005, 0, 0, 1, 0.44, 0, 2, 0.42,
            0.77, 0.23, 65, 0, 0, 1, 0.22, 0.25
        ])
        let colors: [UInt] = [
            0xF4FCFF, 0x8EEBFF, 0x4F9DFF, 0x706BFF,
            0xFFFFFF, 0xFFFFFF, 0x8EEBFF, 0x6A8DFF,
            0xEAF4FF, 0xDCEAFF, 0x030409, 0x55C8FF,
            0xF7FBFF, 0xEFF6FD, 0xE0EEF9, 0xD4E6F7,
            0xBBD5F3, 0xA6C7F0, 0x87B0EB, 0x6F9EE8,
            0x6F9EE8, 0x6F9EE8, 0x6F9EE8, 0x6F9EE8
        ]
        for (index, color) in colors.enumerated() {
            let offset = 32 + index * 4
            values[offset] = Float((color >> 16) & 0xff) / 255
            values[offset + 1] = Float((color >> 8) & 0xff) / 255
            values[offset + 2] = Float(color & 0xff) / 255
            values[offset + 3] = 1
        }
        return values
    }
}
