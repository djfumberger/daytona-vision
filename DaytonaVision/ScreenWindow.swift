import AVFAudio
import QuartzCore
import SwiftUI
import UIKit

/// The game on a flat screen: a standard visionOS window the shape of the
/// arcade monitor, drawn with the cab's CRT look into a Metal layer (no
/// RealityKit: it is an ordinary 2D window, moved and resized as any other).
/// Mono only: a layer cannot show each eye its own picture, so the 3D setting
/// is for the cab. Its shape is the original screen or a widescreen one,
/// chosen from its toolbar; the window keeps that shape as it is resized.
/// Opened from the start volume's Screen button. Played with a controller
/// (hands steer only in the cab). It closes as any window does (back to the
/// start volume); the toolbar below it has reset, the shape, and the help and
/// settings windows.
struct ScreenWindow: View {
    static let windowID = "screen"

    /// Opened with this value, so opening it again brings back the one window.
    static let windowValue = "game"

    /// The window's opening height, in points (its width follows the shape).
    static let defaultHeight: CGFloat = 960

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var stage = ScreenStage()

    var body: some View {
        MetalLayerView(layer: stage.layer) { stage.host = $0 }
            .aspectRatio(model.screenShape.aspect, contentMode: .fit)
            // The controller plays the game, rather than moving the system's focus.
            .handlesGameControllerEvents(matching: .gamepad)
            .toolbar {
                ToolbarItemGroup(placement: .bottomOrnament) { buttons }
            }
            .onAppear {
                model.screenOpen = true
                model.startGame()
                stage.start(model: model)
            }
            .onChange(of: model.screenShape) { _, shape in stage.setShape(shape) }
            .onDisappear {
                stage.stop()
                model.session?.setAspect(0) // the cab and the start volume show the original
                model.screenOpen = false
                model.pauseGame()
                dismissWindow(id: SettingsView.windowID)
                dismissWindow(id: HelpView.windowID)
                // Back to the start volume, if it was closed (it usually stays open).
                if !model.launcherOpen { openWindow(id: LauncherView.windowID) }
            }
    }

    @ViewBuilder private var buttons: some View {
        Button { model.resetGame() } label: {
            Label("Reset", systemImage: "arrow.counterclockwise")
        }
        .help("Reset")

        shapeMenu
        WindowToggle(title: "Help", symbol: "questionmark.circle", id: HelpView.windowID, isOpen: model.showHelp)
        WindowToggle(title: "Settings", symbol: "gearshape", id: SettingsView.windowID, isOpen: model.showSettings)
    }
}

extension ScreenWindow {
    /// The window's shape: the original screen or a widescreen one.
    private var shapeMenu: some View {
        @Bindable var model = model
        return Menu {
            Picker("Shape", selection: $model.screenShape) {
                ForEach(AppModel.ScreenShape.allCases) { Text($0.title).tag($0) }
            }
        } label: {
            Label("Shape", systemImage: "aspectratio")
        }
        .help("Shape")
    }
}

/// A view showing a Metal layer, stretched to its bounds. `onWindow`: the
/// view, once it is in a window (to shape the window).
private struct MetalLayerView: UIViewRepresentable {
    let layer: CAMetalLayer
    let onWindow: (UIView) -> Void

    func makeUIView(context: Context) -> LayerHost { LayerHost(hosted: layer, onWindow: onWindow) }
    func updateUIView(_ view: LayerHost, context: Context) {}

    final class LayerHost: UIView {
        private let hosted: CAMetalLayer
        private let onWindow: (UIView) -> Void

        init(hosted: CAMetalLayer, onWindow: @escaping (UIView) -> Void) {
            self.hosted = hosted
            self.onWindow = onWindow
            super.init(frame: .zero)
            backgroundColor = .black
            layer.addSublayer(hosted)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func layoutSubviews() {
            super.layoutSubviews()
            hosted.frame = bounds
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { onWindow(self) }
        }
    }
}

/// What the flat screen window runs each frame (on the display's beat): the
/// controllers' input to the game, and its newest picture through the CRT
/// kernels into the layer. The sound plays in stereo meanwhile.
@MainActor
final class ScreenStage: NSObject {
    let layer = CAMetalLayer()

    private let input = InputManager()
    private let audio = ScreenAudio()
    private var texture: ScreenTexture?
    private var link: CADisplayLink?
    private weak var model: AppModel?
    private var lastTime: CFTimeInterval?
    private var lastSecond: TimeInterval = 0

    /// The view showing the layer, once in its window: the window takes the shape.
    weak var host: UIView? {
        didSet { if let model { lockShape(model.screenShape) } }
    }

    func start(model: AppModel) {
        self.model = model
        model.session?.setAspect(model.screenShape.coreAspect)
        lockShape(model.screenShape)
        do {
            texture = try ScreenTexture(settings: model.crt, output: .layer(layer))
        } catch {
            model.errorMessage = "Screen: \(error.localizedDescription)"
        }
        model.session?.setStereo(false, depth: model.stereoDepth)

        let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// A new shape: the game drawn to it, and the window to it.
    func setShape(_ shape: AppModel.ScreenShape) {
        model?.session?.setAspect(shape.coreAspect)
        lockShape(shape)
    }

    /// Resizes the window to `shape` (keeping its height) and keeps it to it
    /// as the viewer resizes it.
    private func lockShape(_ shape: AppModel.ScreenShape) {
        guard let window = host?.window, let scene = window.windowScene else { return }
        let height = window.bounds.height > 0 ? window.bounds.height : ScreenWindow.defaultHeight
        let preferences = UIWindowScene.GeometryPreferences.Vision(
            size: CGSize(width: (height * shape.aspect).rounded(), height: height))
        preferences.resizingRestrictions = .uniform
        scene.requestGeometryUpdate(preferences) { error in
            print("ScreenStage: cannot shape the window: \(error)")
        }
    }

    func stop() {
        link?.invalidate()
        link = nil
        lastTime = nil
        audio.stop()
    }

    @objc private func frame(_ link: CADisplayLink) {
        guard let model, let session = model.session else { return }
        let dt = Float(lastTime.map { link.timestamp - $0 } ?? link.duration)
        lastTime = link.timestamp

        audio.play(session) // follows a reset's new session
        session.setInput(input.update(model: model, cab: nil, dt: dt))

        if let texture {
            texture.settings = model.crt // re-processes only when it changed
            texture.update(from: session)
        }

        let now = ProcessInfo.processInfo.systemUptime
        if now - lastSecond >= 1 {
            lastSecond = now
            model.fps = session.fps
            let times = session.frameTimes
            model.frameTimes = (times.game, times.draw, texture?.crtMilliseconds ?? 0)
            model.logPerformance("screen \(model.screenShape.title)", width: texture?.width ?? 0)
            if let error = session.error { model.errorMessage = "Game stopped: \(error)" }
        }
    }
}

/// The game's sound for the flat screen: its two channels as plain stereo
/// (the cab's sound comes from its speakers, in space; a window has none).
@MainActor
final class ScreenAudio {
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private weak var session: GameSession?

    func play(_ session: GameSession) {
        guard session !== self.session else { return }
        stop()
        self.session = session

        let format = AVAudioFormat(standardFormatWithSampleRate: Double(DT_AUDIO_RATE), channels: 2)!
        let source = AVAudioSourceNode(format: format) { isSilence, _, frameCount, outputData in
            let buffers = UnsafeMutableAudioBufferListPointer(outputData)
            for (channel, buffer) in buffers.enumerated() {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                session.readAudio(channel: min(channel, 1), into: data, frames: Int(frameCount))
            }
            isSilence.pointee = false
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            self.source = source
        } catch {
            print("ScreenAudio: cannot start: \(error)")
            engine.detach(source)
        }
    }

    func stop() {
        engine.stop()
        if let source { engine.detach(source) }
        source = nil
        session = nil
    }
}
