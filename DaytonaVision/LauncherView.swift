import RealityKit
import SwiftUI

/// The start volume: a small cab on a stand, with Play, Screen and Settings.
/// The game runs here already, silently, its attract mode on the little cab's
/// screen. Play opens the immersive space, and the big cab grows out of this
/// one (CabStage picks up `AppModel.volumeCabPose` and glides from it), after
/// which this volume is dismissed. Screen opens the game in a flat window
/// instead; this volume stays, its little screen dark while the window has the
/// game. Without a good ROM set, either opens the (out-of-game) settings,
/// where it is chosen, instead.
struct LauncherView: View {
    static let windowID = "launcher"

    /// The volume's size, in metres.
    static let size = SIMD3<Float>(0.6, 0.6, 0.6)

    @Environment(AppModel.self) private var model
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.scenePhase) private var scenePhase

    @State private var turntable = Turntable()

    var body: some View {
        RealityView { content in
            guard let stand = await turntable.load() else { return }
            content.add(stand)
            turntable.showScreen(model: model)

            _ = content.subscribe(to: SceneEvents.Update.self) { [turntable, model] _ in
                turntable.update(model: model)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .bottomOrnament) { controls }
        }
        .onChange(of: canStart, initial: true) { runAttract() }
        // The window closed: back to the attract mode here.
        .onChange(of: model.screenOpen) { _, open in if !open { runAttract() } }
        .onChange(of: scenePhase) { _, phase in
            // Not while playing: this volume goes once the cab has taken over.
            guard !model.playing else { return }
            if phase == .active { runAttract() } else if phase == .background { model.pauseGame() }
        }
        .onAppear { model.launcherOpen = true }
        .onDisappear { model.launcherOpen = false }
        .task {
            // `-autostart`: straight into the cab; `-autoscreen`: the flat screen
            // (development and kiosk use).
            let arguments = ProcessInfo.processInfo.arguments
            guard canStart, !model.playing else { return }
            if arguments.contains("-autostart") { await enterCab() }
            else if arguments.contains("-autoscreen") { openScreen() }
        }
    }

    private var canStart: Bool { model.romReady && model.romOK }

    @ViewBuilder private var controls: some View {
        Button {
            if canStart { Task { await enterCab() } } else { openWindow(id: RomSettingsView.windowID) }
        } label: {
            Label("Play", systemImage: "play.fill")
        }
        .help("Play in the cab")
        .disabled(model.playing)

        Button {
            if canStart { openScreen() } else { openWindow(id: RomSettingsView.windowID) }
        } label: {
            Label("Screen", systemImage: "tv")
        }
        .help("Play on a screen")
        .disabled(model.cabState != .closed)

        Button {
            openWindow(id: RomSettingsView.windowID)
        } label: {
            Label("Settings", systemImage: "gearshape")
        }

        if let error = model.errorMessage {
            Text(error).font(.caption).foregroundStyle(.red)
                .frame(maxWidth: 360)
        }
    }

    /// Runs the game for the little cab's screen, hands off the controls.
    private func runAttract() {
        guard canStart, !model.playing, model.startGame() else { return }
        model.session?.setInput(DTInput(steer: 0, accel: 0, brake: 0, gear: 1, buttons: 0))
    }

    /// The game in the flat screen window (or that window brought back).
    private func openScreen() {
        guard model.startGame() else { return }
        dismissWindow(id: RomSettingsView.windowID)
        openWindow(id: ScreenWindow.windowID, value: ScreenWindow.windowValue)
    }

    private func enterCab() async {
        guard model.startGame() else { return }
        model.cabState = .opening
        dismissWindow(id: RomSettingsView.windowID)

        let turntable = self.turntable
        model.volumeCabPose = { turntable.seat?.transformMatrix(relativeTo: .immersiveSpace) }
        model.volumeHandoffDone = { [dismissWindow] in dismissWindow(id: Self.windowID) }

        switch await openImmersiveSpace(id: AppModel.cabSpaceID) {
        case .opened:
            model.cabState = .open
        default:
            model.cabState = .closed
            model.volumeCabPose = nil
            model.volumeHandoffDone = nil
            model.pauseGame()
        }
    }
}

/// The little cab on its stand, still. `seat` marks the driver's seat on the floor,
/// where the big cab's root goes, so its pose is where the big one starts.
@MainActor
final class Turntable {
    private let stand = Entity()
    private let spinner = Entity()
    private(set) var seat: Entity?

    /// The little cab's game screen, and what draws on it once the game runs.
    private var screen: ModelEntity?
    private var texture: ScreenTexture?
    private var phosphor: UnlitMaterial?

    /// Dark while the flat screen window has the game, so it is drawn once.
    private var dark = false

    /// Its front (the screen side) to the player; the big cab grows straight into place round them.
    private let angle: Float = 0

    func load() async -> Entity? {
        guard let url = Bundle.main.url(forResource: "Cab", withExtension: "usdz"),
              let cab = try? await Entity(contentsOf: url) else { return nil }

        let bounds = cab.visualBounds(relativeTo: cab)
        let size = LauncherView.size

        // Fit with a margin: the whole turn has to stay inside the volume.
        let radius = simd_length(SIMD2(bounds.extents.x, bounds.extents.z)) / 2
        let scale = min(size.x * 0.42 / radius, size.y * 0.85 / bounds.extents.y)

        // Centre the cab's footprint on the spinner, its floor on the stand.
        cab.position = [-bounds.center.x, -bounds.min.y, -bounds.center.z]
        spinner.addChild(cab)
        spinner.scale = SIMD3(repeating: scale)
        stand.addChild(spinner)
        stand.position = [0, -size.y / 2 + 0.01, 0]

        let seat = Entity()
        if let eye = cab.findEntity(named: "EyePoint") {
            let p = eye.position(relativeTo: cab)
            seat.position = [p.x, 0, p.z]
        }
        cab.addChild(seat)
        self.seat = seat

        let screenEntity = cab.findEntity(named: "Screen") ?? cab.findEntity(named: "CRT_Screen")
        screen = screenEntity as? ModelEntity ?? screenEntity?.children.compactMap { $0 as? ModelEntity }.first

        let disc = ModelEntity(
            mesh: .generateCylinder(height: 0.008, radius: radius * scale + 0.02),
            materials: [SimpleMaterial(color: UIColor(white: 0.08, alpha: 1), roughness: 0.35, isMetallic: true)]
        )
        disc.position.y = -0.004
        stand.addChild(disc)

        apply()
        return stand
    }

    /// Puts the game's picture on the screen (dark until the game runs).
    func showScreen(model: AppModel) {
        guard let screen, texture == nil,
              let texture = try? ScreenTexture(settings: model.crt, scanlines: false) else { return }

        var phosphor = UnlitMaterial()
        phosphor.color = .init(tint: .white, texture: .init(texture.resource))
        screen.model?.materials = [phosphor]
        self.phosphor = phosphor
        self.texture = texture
    }

    /// Each frame: the game's newest picture, unless the flat screen has it.
    func update(model: AppModel) {
        if model.screenOpen != dark, let phosphor {
            dark = model.screenOpen
            screen?.model?.materials = [dark ? UnlitMaterial(color: .black) : phosphor]
        }
        guard !dark, let texture, let session = model.session else { return }
        texture.settings = model.crt
        texture.update(from: session)
    }

    private func apply() { spinner.orientation = simd_quatf(angle: angle, axis: [0, 1, 0]) }
}
