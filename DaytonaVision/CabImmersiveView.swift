import GameController
import RealityKit
import SwiftUI

/// The immersive space: the cab around the driver, its screen showing the
/// game, its speakers playing it, and the inputs driving it every frame.
struct CabImmersiveView: View {
    @Environment(AppModel.self) private var model
    @State private var stage = CabStage()
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        RealityView { content, attachments in
            let cab = await Cab()
            content.add(cab.root)
            content.add(cab.placer)

            if let toolbar = attachments.entity(for: "toolbar") {
                toolbar.position = cab.toolbarPosition
                toolbar.scale = [0.8, 0.8, 0.8]
                toolbar.orientation = simd_quatf(angle: -0.25, axis: [1, 0, 0])
                cab.rig.addChild(toolbar)
                toolbar.isEnabled = model.showToolbar
                stage.toolbar = toolbar
            }

            if let done = attachments.entity(for: "spotDone") {
                // Over the ring's middle, turned to whoever is looking.
                done.position = cab.placerCentreLocal + [0, 0.4, 0]
                done.components.set(BillboardComponent())
                done.isEnabled = false
                cab.placer.addChild(done)
                stage.spotDone = done
            }

            stage.attach(cab: cab, model: model, content: content)
        } attachments: {
            Attachment(id: "spotDone") {
                VStack(spacing: 10) {
                    Image(systemName: "move.3d")
                        .font(.title)
                        .foregroundStyle(.tint)
                    Text("Drag the ring to place the cab; drag its edge to turn it.")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .frame(width: 300)
                    Button { stage.finishPlacing(model: model) } label: {
                        Text("Done").padding(.horizontal, 12)
                    }
                }
                .padding(18)
                .glassBackgroundEffect()
            }

            Attachment(id: "toolbar") {
                CabToolbar(onDone: { stage.finishPlacing(model: model) }).environment(model)
            }
        }
        .gesture(
            SpatialTapGesture()
                .targetedToAnyEntity()
                .onEnded { value in stage.tapped(value.entity, model: model) }
        )
        .simultaneousGesture(
            DragGesture()
                .targetedToAnyEntity()
                .onChanged { value in stage.dragChanged(value) }
                .onEnded { _ in stage.dragEnded() }
        )
        // The controller reaches the game wherever you look: without these,
        // gaze on something tappable (the screen) takes its buttons. As in
        // vision-emulator; focusable() is needed for the view to hold them.
        .focusable()
        .focusEffectDisabled()
        .handlesGameControllerEvents(matching: .gamepad)
        .task { await stage.input.start() }
        .onAppear { if model.showSettings { openWindow(id: SettingsView.windowID) } }
        .onChange(of: model.placing) { _, placing in
            if placing { stage.beginPlacing(model: model) }
        }
        .onChange(of: model.fullImmersion) { _, full in stage.cab?.environment.isEnabled = full }
        .onDisappear {
            // Leaving before the hand-off finished: the volume is still there.
            model.volumeCabPose = nil
            model.volumeHandoffDone = nil
            stage.detach()
            model.placing = false // a new visit decides for itself
            model.session?.setStereo(false, depth: model.stereoDepth) // the start volume's screen is mono
            dismissWindow(id: SettingsView.windowID)
            dismissWindow(id: HelpView.windowID)
            model.pauseGame()
            model.cabState = .closed
        }
    }
}

@MainActor
@Observable
final class CabStage {
    let input = InputManager()
    private(set) var cab: Cab?
    private var screen: ScreenTexture?

    /// The stereo screen's material (StereoScreen.usda), once loaded.
    private var stereoMaterial: ShaderGraphMaterial?

    /// What the session and screen are set up for: stereo, at what depth.
    private var stereoShown: (on: Bool, depth: Float, session: ObjectIdentifier?)?

    private let audio = CabAudio()

    /// The session the speakers play (a reset makes a new one).
    private weak var audioSession: GameSession?

    private var updates: EventSubscription?

    /// Panels shown and hidden with the model's flags (always laid out, so they
    /// appear at their full size when enabled).
    var toolbar: Entity?

    private var lastSecond: TimeInterval = 0

    func attach(cab: Cab, model: AppModel, content: RealityViewContent) {
        self.cab = cab
        cab.environment.isEnabled = model.fullImmersion
        model.session?.setAspect(0) // the cab's screen is the original

        // Until head tracking says otherwise: a seated driver at the origin.
        cab.place(head: Self.defaultHead)

        do {
            try showScreen(on: cab, stereo: false, model: model)
            Task { [weak self] in
                self?.stereoMaterial = try? await ShaderGraphMaterial(
                    named: "/Root/StereoScreen", from: "StereoScreen.usda", in: Bundle.main)
            }
        } catch {
            model.errorMessage = "Screen: \(error.localizedDescription)"
        }

        arriving = true
        model.session?.paused = false

        updates = content.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            self?.tick(dt: Float(event.deltaTime), model: model)
        }
    }

    /// A screen texture (both eyes stacked, in stereo) and the material showing it.
    private func showScreen(on cab: Cab, stereo: Bool, model: AppModel) throws {
        let screen = try ScreenTexture(settings: model.crt, stereo: stereo)
        if stereo, var material = stereoMaterial {
            try material.setParameter(name: "Screen", value: .textureResource(screen.resource))
            cab.setScreenMaterial(material)
        } else {
            cab.setScreenMaterial(screen.resource)
        }
        self.screen = screen
    }

    /// Follows the stereo setting: the game draws both eyes, the screen shows
    /// each its own (once the stereo material has loaded).
    private func updateStereo(cab: Cab, session: GameSession, model: AppModel) {
        let on = model.stereo3D && stereoMaterial != nil
        let wanted = (on: on, depth: model.stereoDepth, session: ObjectIdentifier(session))
        if let shown = stereoShown, shown == wanted { return }
        session.setStereo(on, depth: model.stereoDepth)
        if stereoShown?.on != on { try? showScreen(on: cab, stereo: on, model: model) }
        stereoShown = wanted
    }

    func detach() {
        stereoShown = nil
        updates?.cancel()
        updates = nil
        audio.stop()
        audioSession = nil
        input.stop()
    }

    private func tick(dt: Float, model: AppModel) {
        guard let cab else { return }

        if arriving, let head = input.headTransform() {
            arrive(cab: cab, head: head, model: model)
        }
        if choosingSpot || growPending {
            updateArrival(cab: cab, head: input.headTransform(), model: model)
        }
        spotDone?.isEnabled = choosingSpot
        cab.setGlassOpacity(model.crt.glassOpacity)
        toolbar?.isEnabled = model.showToolbar || model.placing
        cab.animateRoom(dt: dt)

        guard let session = model.session else { return }

        if session !== audioSession {
            audio.start(session: session, left: cab.speakerL, right: cab.speakerR)
            audioSession = session
        }

        session.setInput(input.update(model: model, cab: cab, dt: dt))
        updateStereo(cab: cab, session: session, model: model)

        if let screen {
            screen.settings = model.crt // re-processes only when it changed
            screen.update(from: session)
        }

        let now = ProcessInfo.processInfo.systemUptime
        if now - lastSecond >= 1 {
            lastSecond = now
            model.fps = session.fps
            let times = session.frameTimes
            model.frameTimes = (times.game, times.draw, screen?.crtMilliseconds ?? 0)
            model.logPerformance("cab", width: screen?.width ?? 0)
            if let error = session.error { model.errorMessage = "Game stopped: \(error)" }
        }
    }

    // MARK: Growing out of the start volume

    private var volumeTicks = 0
    private var lastVolumePose: simd_float4x4?
    private var agreedTicks = 0

    /// Whether the cab can be placed yet and, if it came from the start
    /// volume, the pose to grow from. The volume's answer is only taken once
    /// the head is tracked, it lies roughly ahead (early answers can be against
    /// a stale frame) and it has held still for a few ticks; after about two
    /// seconds without one the cab simply appears. Returns nil to wait,
    /// `.some(nil)` to place without a glide.
    private func volumeStart(model: AppModel, head: simd_float4x4) -> simd_float4x4?? {
        guard let read = model.volumeCabPose else { return .some(nil) }

        volumeTicks += 1
        if let pose = read(), Self.plausible(pose, head: head) {
            if let last = lastVolumePose, (0..<4).allSatisfy({ simd_distance(last[$0], pose[$0]) < 0.003 }) {
                agreedTicks += 1
            } else {
                agreedTicks = 0
            }
            lastVolumePose = pose
            if agreedTicks >= 3 {
                finishHandoff(model: model)
                return .some(pose)
            }
        } else {
            lastVolumePose = nil
            agreedTicks = 0
        }

        if volumeTicks > 180 {
            finishHandoff(model: model)
            return .some(nil)
        }
        return nil
    }

    private func finishHandoff(model: AppModel) {
        let done = model.volumeHandoffDone
        model.volumeCabPose = nil
        model.volumeHandoffDone = nil
        done?()
    }

    /// Within 70° of where the head faces, and at a sane range.
    private static func plausible(_ pose: simd_float4x4, head: simd_float4x4) -> Bool {
        let to = pose.columns.3 - head.columns.3
        let flatTo = SIMD2<Float>(to.x, to.z), flatFwd = -SIMD2<Float>(head.columns.2.x, head.columns.2.z)
        let distance = simd_length(flatTo)
        guard distance > 0.1, distance < 5, simd_length(flatFwd) > 1e-3 else { return false }

        return simd_dot(flatTo / distance, simd_normalize(flatFwd)) > 0.35
    }

    // MARK: Arriving

    /// The cab's saved spot (a world anchor, kept by the system between sessions).
    private static let anchorKey = "cabAnchorID"

    private var savedAnchor: UUID? {
        get { UserDefaults.standard.string(forKey: Self.anchorKey).flatMap(UUID.init) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: Self.anchorKey) }
    }

    /// The cab has yet to be put anywhere this visit.
    private var arriving = true

    private var anchorWait = 0

    init() {
        // `-forgetSpot`: start without the saved spot, to choose one again (development).
        if ProcessInfo.processInfo.arguments.contains("-forgetSpot") { savedAnchor = nil }
    }

    /// Choosing a spot with no saved one to go to: the ring alone, the cab
    /// still in the start volume until Done.
    private(set) var choosingSpot = false

    /// The ring has been moved (so a late-found saved spot no longer applies).
    private var adjusted = false

    /// The spot is chosen: the cab grows into it from the start volume.
    private var growPending = false

    /// The floating Done shown while choosing a spot.
    var spotDone: Entity?

    /// Puts the cab where it was left, if the system finds that spot (in about
    /// two seconds); if not, shows the ring on the floor to choose one.
    private func arrive(cab: Cab, head: simd_float4x4, model: AppModel) {
        let saved = savedAnchor.flatMap { input.anchorTransform($0) }
        if saved == nil, savedAnchor != nil, anchorWait < 120 {
            anchorWait += 1
            return
        }

        if let saved {
            guard let from = volumeStart(model: model, head: head) else { return }
            arriving = false
            cab.place(seat: saved, eyeHeight: max(0.8, head.columns.3.y), growingFrom: from)
        } else {
            arriving = false
            cab.place(head: head) // where the ring starts: around the driver
            cab.root.isEnabled = false
            choosingSpot = true
            adjusted = false
            model.placing = true
        }
    }

    /// While choosing: a saved spot the system finds late wins, if the ring
    /// has not been touched. Once chosen: grows the cab in.
    private func updateArrival(cab: Cab, head: simd_float4x4?, model: AppModel) {
        guard let head else { return }

        if choosingSpot, !adjusted, let id = savedAnchor, let saved = input.anchorTransform(id) {
            cab.place(seat: saved, eyeHeight: max(0.8, head.columns.3.y))
            choosingSpot = false
            cab.endPlacing()
            model.placing = false
            growPending = true
        }

        if growPending, let from = volumeStart(model: model, head: head) {
            growPending = false
            cab.root.isEnabled = true
            cab.glide(from: from)
        }
    }

    // MARK: Placing

    private var dragOffset: SIMD3<Float>?

    /// While turning: the grab point's angle about the ring's centre, and the yaw, at the start.
    private var turnStart: (angle: Float, yaw: Float)?

    func beginPlacing(model: AppModel) {
        guard let cab, !cab.isPlacing else { return }
        cab.beginPlacing()
    }

    /// Leaves place mode and (unless it came from the saved spot) saves where
    /// the cab is, for next time.
    func finishPlacing(model: AppModel, save: Bool = true) {
        if choosingSpot {
            choosingSpot = false
            growPending = true
        }
        cab?.endPlacing()
        model.placing = false
        model.showToolbar = false

        guard save, let seat = cab?.seatTransform else { return }
        let old = savedAnchor
        Task {
            if let id = await input.replaceAnchor(old, with: seat) { savedAnchor = id }
        }
    }

    /// Dragging inside the ring moves it on the floor; dragging the ring turns
    /// it, following the hand round its centre.
    func dragChanged(_ value: EntityTargetValue<DragGesture.Value>) {
        guard let cab, cab.isPlacing else { return }
        adjusted = true

        let p = value.convert(value.location3D, from: .local, to: .scene)
        switch value.entity.name {
        case Cab.placerTurnName:
            let d = p - cab.placerCentre
            guard simd_length(SIMD2(d.x, d.z)) > 0.05 else { return }
            let angle = atan2(-d.x, -d.z)
            if turnStart == nil { turnStart = (angle, cab.placerYaw) }
            if let start = turnStart { cab.setPlacerYaw(start.yaw + angle - start.angle) }
        case Cab.placerBodyName:
            if dragOffset == nil { dragOffset = cab.placer.position - p } // keep the grab point under the hand
            cab.movePlacer(to: p + (dragOffset ?? .zero))
        default:
            break
        }
    }

    func dragEnded() {
        dragOffset = nil
        turnStart = nil
    }

    func tapped(_ entity: Entity, model: AppModel) {
        // The screen toggles the toolbar, but not while a hand is on the wheel:
        // pinching there is the gas.
        if let cab, cab.isScreen(entity) {
            if model.handsOnWheel == 0, !model.placing { model.showToolbar.toggle() }
            return
        }

        let buttons: [String: UInt32] = [
            "start": UInt32(DT_BTN_START), "coin": UInt32(DT_BTN_COIN),
            "view1": UInt32(DT_BTN_VIEW1), "view2": UInt32(DT_BTN_VIEW2),
            "view3": UInt32(DT_BTN_VIEW3), "view4": UInt32(DT_BTN_VIEW4),
            "test": UInt32(DT_BTN_TEST), "service": UInt32(DT_BTN_SERVICE),
        ]

        var e: Entity? = entity
        while let current = e { // the tap may land on a child of the named button
            if let id = Cab.buttonID(current.name), let button = buttons[id] {
                model.tap(button)
                pulse(current)
                return
            }
            e = current.parent
        }
    }

    /// Pushes a button in and lets it spring back. Buttons' origins are not at
    /// their centres (scaling them slides them about), so it moves the cap along
    /// its thinnest axis, the plate's normal, away from the player.
    private var buttonRest: [ObjectIdentifier: Transform] = [:]

    private func pulse(_ entity: Entity) {
        // Its resting place from the first press, so quick repeats don't creep.
        let rest = buttonRest[ObjectIdentifier(entity)] ?? entity.transform
        buttonRest[ObjectIdentifier(entity)] = rest

        let bounds = entity.visualBounds(relativeTo: entity)
        let e = bounds.extents
        var axis: SIMD3<Float> = e.x <= e.y && e.x <= e.z ? [1, 0, 0] : (e.y <= e.z ? [0, 1, 0] : [0, 0, 1])
        let depth = min(0.005, max(0.002, min(e.x, min(e.y, e.z)) * 0.6))

        // Into the cab: away from the head (or, without tracking, the eye point's side).
        let centre = entity.convert(position: bounds.center, to: nil)
        let worldAxis = entity.convert(direction: axis, to: nil)
        let head = input.headTransform().map { SIMD3<Float>($0.columns.3.x, $0.columns.3.y, $0.columns.3.z) }
            ?? (cab.map { $0.root.position(relativeTo: nil) + [0, 1.2, 0] } ?? .zero)
        if simd_dot(worldAxis, centre - head) < 0 { axis = -axis }

        // The axis is in the entity's own frame; the translation is in its parent's.
        let offset = rest.matrix * SIMD4<Float>(axis * depth, 0)
        var pressed = rest
        pressed.translation += SIMD3(offset.x, offset.y, offset.z)
        entity.move(to: pressed, relativeTo: entity.parent, duration: 0.05)

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(110))
            entity.move(to: rest, relativeTo: entity.parent, duration: 0.1)
        }
    }

    private static let defaultHead: simd_float4x4 = {
        var m = matrix_identity_float4x4
        m.columns.3 = [0, 1.2, 0, 1]
        return m
    }()
}
