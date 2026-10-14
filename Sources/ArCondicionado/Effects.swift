import AppKit
import MetalKit
import SwiftUI

/// Quando ligado, efeitos que não aparecem em captura offscreen (vidro, Metal)
/// são trocados por equivalentes estáticos. Usado só pelo gerador de screenshots.
enum SnapshotMode {
    @MainActor static var isOn = false
}

// MARK: - Vidro nativo (mesmo material do Control Center)

struct Glass: View {
    var body: some View {
        if SnapshotMode.isOn {
            Color(red: 0.11, green: 0.12, blue: 0.15).opacity(0.92)
        } else {
            GlassBackground()
        }
    }
}

struct GlassBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .vibrantDark)
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
    }
}

// MARK: - Háptico do trackpad

enum Haptics {
    static func tick() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }
    static func edge() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

// MARK: - Fluxo de ar em shader Metal
//
// O shader é compilado em tempo de execução a partir do código-fonte abaixo,
// então não depende do compilador `metal` do Xcode no build.

private let airflowShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4 color;
    float time;
    float speed;
    float intensity;
    float pad;
};

struct VOut { float4 pos [[position]]; float2 uv; };

vertex VOut airflow_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);   // y cresce para baixo
    return o;
}

static float hash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

static float noise(float2 p) {
    float2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash(i), b = hash(i + float2(1, 0));
    float c = hash(i + float2(0, 1)), d = hash(i + float2(1, 1));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

fragment float4 airflow_fragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    float2 uv = in.uv;
    float t = u.time * u.speed;

    // cone que abre conforme o ar desce
    float spread = 0.34 + uv.y * 0.30;
    float x = (uv.x - 0.5) / spread;
    float cone = 1.0 - smoothstep(0.55, 1.0, abs(x));

    // filetes finos descendo, levemente ondulados
    float wobble = sin(uv.y * 6.0 - t * 1.3 + x * 3.0) * 0.06;
    float streaks = noise(float2((x + wobble) * 34.0, uv.y * 2.4 - t * 1.8));
    streaks = pow(smoothstep(0.58, 1.0, streaks), 1.7);

    // névoa larga e lenta
    float mist = noise(float2(x * 3.0 + t * 0.15, uv.y * 3.0 - t * 0.9));
    mist = smoothstep(0.35, 1.0, mist) * 0.30;

    // nasce na saída do split e some antes do centro do dial
    float fade = smoothstep(0.0, 0.05, uv.y) * (1.0 - smoothstep(0.18, 0.62, uv.y));

    float a = (streaks * 0.75 + mist) * cone * fade * u.intensity * 1.15;
    a = clamp(a, 0.0, 1.0);
    return float4(u.color.rgb * a, a);   // alfa pré-multiplicado
}
"""

/// Fluxo de ar animado; no modo snapshot vira um quadro estático do mesmo shader.
struct Airflow: View {
    let color: Color
    let on: Bool
    let strength: Double

    var body: some View {
        if SnapshotMode.isOn {
            GeometryReader { geo in
                if on, let img = AirflowView.Renderer().still(size: geo.size, scale: 2, color: color, strength: strength) {
                    Image(decorative: img, scale: 2)
                }
            }
        } else {
            AirflowView(color: color, on: on, strength: strength)
        }
    }
}

struct AirflowView: NSViewRepresentable {
    let color: Color
    let on: Bool
    /// 0…1 — força do vento (ventilação)
    let strength: Double

    func makeCoordinator() -> Renderer { Renderer() }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.delegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.layer?.isOpaque = false
        view.preferredFramesPerSecond = 60
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        let r = context.coordinator
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .white
        r.color = SIMD4(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent), 1)
        r.targetIntensity = on ? Float(0.55 + strength * 0.45) : 0
        r.speed = Float(0.6 + strength * 0.9)
        view.isPaused = false
    }

    final class Renderer: NSObject, MTKViewDelegate {
        struct Uniforms {
            var color: SIMD4<Float>
            var time: Float
            var speed: Float
            var intensity: Float
            var pad: Float = 0
        }

        let device = MTLCreateSystemDefaultDevice()
        private var pipeline: MTLRenderPipelineState?
        private var queue: MTLCommandQueue?
        private let start = CACurrentMediaTime()

        var color = SIMD4<Float>(1, 1, 1, 1)
        var speed: Float = 1
        var targetIntensity: Float = 0
        private var intensity: Float = 0

        override init() {
            super.init()
            guard let device,
                  let lib = try? device.makeLibrary(source: airflowShaderSource, options: nil) else { return }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = lib.makeFunction(name: "airflow_vertex")
            desc.fragmentFunction = lib.makeFunction(name: "airflow_fragment")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try? device.makeRenderPipelineState(descriptor: desc)
            queue = device.makeCommandQueue()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        /// Renderiza um quadro numa textura offscreen (para screenshots).
        func still(size: CGSize, scale: CGFloat, color: Color, strength: Double, time: Float = 3.7) -> CGImage? {
            guard let device, let pipeline, let queue else { return nil }
            let w = Int(size.width * scale), h = Int(size.height * scale)
            guard w > 0, h > 0 else { return nil }
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            td.usage = [.renderTarget, .shaderRead]
            td.storageMode = .managed
            guard let tex = device.makeTexture(descriptor: td) else { return nil }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = tex
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            pass.colorAttachments[0].storeAction = .store
            let c = NSColor(color).usingColorSpace(.sRGB) ?? .white
            var u = Uniforms(color: SIMD4(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent), 1),
                             time: time, speed: Float(0.6 + strength * 0.9), intensity: Float(0.55 + strength * 0.45))
            guard let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return nil }
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
            if let blit = cmd.makeBlitCommandEncoder() { blit.synchronize(resource: tex); blit.endEncoding() }
            cmd.commit(); cmd.waitUntilCompleted()
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            tex.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
            return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info,
                           provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }

        func draw(in view: MTKView) {
            // liga/desliga com transição suave; pausa quando apagado
            intensity += (targetIntensity - intensity) * 0.06
            if targetIntensity == 0 && intensity < 0.005 { intensity = 0; view.isPaused = true }

            guard let pipeline, let queue,
                  let pass = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable,
                  let cmd = queue.makeCommandBuffer(),
                  let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
            var u = Uniforms(color: color, time: Float(CACurrentMediaTime() - start), speed: speed, intensity: intensity)
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
            cmd.present(drawable)
            cmd.commit()
        }
    }
}

// MARK: - Split (unidade interna)

struct ACUnitView: View {
    let on: Bool
    let temp: Int
    let tint: Color

    var body: some View {
        ZStack(alignment: .bottom) {
            // corpo
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(stops: [.init(color: .white, location: 0),
                                             .init(color: Color(white: 0.95), location: 0.3),
                                             .init(color: Color(white: 0.84), location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(.white.opacity(0.6), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.45), radius: 12, y: 6)

            // painel com a temperatura
            HStack {
                Circle()
                    .fill(on ? Color.green.opacity(0.8) : Color(white: 0.7))
                    .frame(width: 3.5, height: 3.5)
                Spacer()
                Text(on ? "\(temp)" : "--")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(on ? tint : Color(white: 0.7))
                    .shadow(color: on ? tint.opacity(0.8) : .clear, radius: 3)
                    .contentTransition(.numericText(value: Double(temp)))
            }
            .padding(.horizontal, 16)
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 13)

            // saída de ar + aleta que abre
            ZStack(alignment: .top) {
                Capsule().fill(Color(white: 0.12)).frame(height: 8)
                Capsule()
                    .fill(LinearGradient(colors: [Color(white: 0.92), Color(white: 0.78)], startPoint: .top, endPoint: .bottom))
                    .frame(height: 7)
                    // aleta "abrindo": achata vista de frente e desce um pouco
                    .scaleEffect(x: on ? 0.97 : 1, y: on ? 0.45 : 1, anchor: .top)
                    .offset(y: on ? 4 : 0.5)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 9)
        }
        .frame(width: 216, height: 62)
        .animation(.spring(duration: 0.7, bounce: 0.25), value: on)
    }
}

// MARK: - Ventilador girando na velocidade escolhida

struct SpinningFan: View {
    /// voltas por segundo; 0 = parado
    let rps: Double

    /// Fase acumulada fora do ciclo de estado do SwiftUI, pra mudar de velocidade sem dar salto.
    private final class Phase { var angle = 0.0; var last: Date? }
    @State private var phase = Phase()

    var body: some View {
        TimelineView(.animation(paused: rps == 0)) { ctx in
            Image(systemName: "fan")
                .rotationEffect(.degrees(advance(to: ctx.date)))
        }
    }

    private func advance(to date: Date) -> Double {
        let dt = min(date.timeIntervalSince(phase.last ?? date), 0.1)
        phase.last = date
        phase.angle = (phase.angle + dt * rps * 360).truncatingRemainder(dividingBy: 360)
        return phase.angle
    }
}
