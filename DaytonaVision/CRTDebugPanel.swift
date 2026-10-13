import SwiftUI
import UIKit

/// Live tuning for the screen, and the game's status: the renderer (GPU 3× unless changed here),
/// every CRT shader setting, the texture sampling, and the glass, with their
/// values. Changes apply at once (even paused) and are kept between launches.
/// Pushed from the settings' Display tab.
struct CRTDebugPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Form {
            Section {
                Picker("Renderer", selection: $model.renderScale) {
                    Text("CPU").tag(0)
                    Text("GPU").tag(1)
                    Text("GPU 2×").tag(2)
                    Text("GPU 3×").tag(3)
                }
                .pickerStyle(.menu)
            }

            Section {
                Toggle("Mip smoothing", isOn: $model.crt.mipSmoothing)
            } footer: {
                Text("Off samples the full \(ScreenTexture.outputSize.width)×\(ScreenTexture.outputSize.height) texture: sharpest lines, may shimmer.")
            }

            Section("Scanlines") {
                slider("Strength", $model.crt.scanlines, 0...1)
                slider("Beam at black", $model.crt.minBeam, 0.05...0.6)
                slider("Beam at white", $model.crt.maxBeam, 0.05...0.8)
                slider("Horizontal blur", $model.crt.blur, 0...2)
                slider("Brightness", $model.crt.brightness, 0.5...2)
            }

            Section("Bloom") {
                slider("Amount", $model.crt.bloom, 0...1.5)
                slider("Threshold", $model.crt.bloomThreshold, 0...1)
                slider("Radius (px)", $model.crt.bloomRadius, 1...16)
            }

            Section("Old tube") {
                slider("Soft edges", $model.crt.edgeBlur, 0...3)
                slider("Convergence (px)", $model.crt.convergence, 0...2)
                slider("Edge misconvergence (px)", $model.crt.misconvergence, 0...3)
                slider("Degauss stains", $model.crt.purity, 0...0.6)
            }

            Section("Glass") {
                slider("Reflection", $model.crt.glassOpacity, 0...0.5)
            }

            Section {
                Button("Copy JSON") { UIPasteboard.general.string = model.crt.json }
                Button("Reset to \(model.crtTube.title)", role: .destructive) { model.crt = model.crtTube.settings }
            } footer: {
                Text(status).monospacedDigit()
            }
        }
        .formStyle(.grouped)
    }

    /// What the inputs are doing and how fast the game runs.
    private var status: String {
        let t = model.frameTimes
        var parts = [String(format: "%.1f fps (game %.1f ms, draw %.1f ms, CRT %.1f ms)", model.fps, t.game, t.draw, t.crt)]
        if model.handTrackingAvailable { parts.append("hands on wheel: \(model.handsOnWheel)") }
        if let name = model.controllerName { parts.append(name) }
        parts.append(String(format: "steer %+.2f · gas %.2f · brake %.2f", model.steer, model.accel, model.brake))
        return parts.joined(separator: " · ")
    }

    private func slider(_ label: String, _ value: Binding<Float>, _ range: ClosedRange<Float>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(label, value: String(format: "%.2f", value.wrappedValue))
            Slider(value: value, in: range)
        }
    }
}
