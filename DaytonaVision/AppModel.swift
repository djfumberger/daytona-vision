import Foundation
import Observation
import simd

@MainActor
@Observable
final class AppModel {
    static let cabSpaceID = "Cab"

    enum CabState { case closed, opening, open }

    // ROM and game
    var romURL: URL? = GameSession.storedROM()

    /// The stored ROM set passed its check; if not, why (nil when it passed).
    var romOK = false
    var romProblem: String?

    var errorMessage: String?
    private(set) var session: GameSession?

    // Immersive space
    var cabState: CabState = .closed
    /// The arcade room (full immersion) round the cab (`-arcaderoom` starts in it).
    var fullImmersion = ProcessInfo.processInfo.arguments.contains("-arcaderoom")

    /// The flat screen window is open.
    var screenOpen = false

    /// The start volume is open (it is a window group: opening it again would
    /// make a second one).
    var launcherOpen = false

    /// The flat screen window's shape: the original screen, or widescreen
    /// (the game shows more at the sides). The cab is always the original.
    enum ScreenShape: String, CaseIterable, Identifiable {
        case original, wide16x10, wide16x9, wide21x9

        var id: Self { self }

        var title: String {
            switch self {
            case .original: "Original"
            case .wide16x10: "16:10"
            case .wide16x9: "16:9"
            case .wide21x9: "21:9"
            }
        }

        /// Width / height, as the game draws it (GameLoop::wide_margin rounds
        /// the width to whole pixel pairs).
        var aspect: Double {
            switch self {
            case .original: Double(GameSession.originalWidth) / Double(GameSession.screenHeight)
            case .wide16x10: 16.0 / 10
            case .wide16x9: 16.0 / 9
            case .wide21x9: 21.0 / 9
            }
        }

        /// For the core (dt_set_aspect): 0 the original.
        var coreAspect: Double { self == .original ? 0 : aspect }
    }

    var screenShape = UserDefaults.standard.string(forKey: "screenShape").flatMap(ScreenShape.init) ?? .original {
        didSet { UserDefaults.standard.set(screenShape.rawValue, forKey: "screenShape") }
    }

    /// The game is being played, in the cab or on the flat screen (not the
    /// start volume's attract mode).
    var playing: Bool { cabState != .closed || screenOpen }

    // Player settings
    var gear: Int32 = 1
    var autoGas = false

    /// The screen's CRT look (CRT.metal) and glass, kept between launches.
    var crt = CRTSettings.load() { didSet { crt.save() } }

    /// Who draws the game: 0 the CPU (upstream's reference rasterizer), 1-3 the
    /// GPU (Metal) at that multiple of the original resolution. GPU 3× unless
    /// changed in the Debug settings; the CPU in the simulator, whose Metal
    /// cannot make the GPU renderer's textures over shared buffers.
    var renderScale = UserDefaults.standard.object(forKey: "renderScale") as? Int ?? AppModel.defaultRenderScale {
        didSet {
            UserDefaults.standard.set(renderScale, forKey: "renderScale")
            session?.setRenderer(scale: renderScale)
        }
    }

    #if targetEnvironment(simulator)
    static let defaultRenderScale = 0
    #else
    static let defaultRenderScale = 3
    #endif

    /// The tube's age: picking one sets `crt` to it.
    var crtTube = UserDefaults.standard.string(forKey: "crtTube").flatMap(CRTSettings.Tube.init) ?? .midLife {
        didSet {
            UserDefaults.standard.set(crtTube.rawValue, forKey: "crtTube")
            crt = crtTube.settings
        }
    }

    /// The settings and help windows are open (`-crtdebug` opens settings on entering the cab).
    var showSettings = ProcessInfo.processInfo.arguments.contains("-crtdebug")
    var showHelp = false

    var settingsTab = SettingsView.Tab.display

    /// Set by the start volume when it opens the cab: where its little cab's
    /// driver seat is, in the immersive space (readable only while the space is
    /// open), and what to do once the big cab has taken over from it.
    var volumeCabPose: (() -> simd_float4x4?)?
    var volumeHandoffDone: (() -> Void)?

    /// The toolbar under the screen (toggled by pinching the screen).
    var showToolbar = ProcessInfo.processInfo.arguments.contains("-toolbar")

    /// Placing the cab: a ring on the floor around it is dragged to move and turn it.
    var placing = false

    var volume: Float = 0.8 { didSet { session?.setVolume(volume) } }

    /// Stereo 3D on the cab's screen (the 3D drawn for each eye), and how
    /// deep: the most the eyes' pictures differ, in screen pixels.
    var stereo3D = UserDefaults.standard.bool(forKey: "stereo3D") {
        didSet { UserDefaults.standard.set(stereo3D, forKey: "stereo3D") }
    }

    static let stereoDepthRange: ClosedRange<Float> = 0...10

    var stereoDepth: Float = (UserDefaults.standard.object(forKey: "stereoDepth") as? Float ?? 5)
        .clamped(to: AppModel.stereoDepthRange) {
        didSet { UserDefaults.standard.set(stereoDepth, forKey: "stereoDepth") }
    }

    /// How directly a controller's stick steers: 1 straight, 0 gentlest near the middle.
    var stickSensitivity: Float = UserDefaults.standard.object(forKey: "stickSensitivity") as? Float ?? 0.4 {
        didSet { UserDefaults.standard.set(stickSensitivity, forKey: "stickSensitivity") }
    }

    /// Wheel rotation, either way, that gives full lock.
    var wheelLockDegrees: Float = 120

    // Live telemetry (the Debug panel's status line)
    var steer: Float = 0
    var accel: Float = 0
    var brake: Float = 0
    var handsOnWheel = 0
    var handTrackingAvailable = false
    var controllerName: String?
    var fps: Double = 0
    /// Milliseconds per frame (smoothed): the game thread running the game and
    /// drawing it, and the screen's CRT pass on the GPU.
    var frameTimes: (game: Float, draw: Float, crt: Double) = (0, 0, 0)

    /// Buttons held from the settings' operator buttons or the cab's 3D buttons, until a time.
    private var heldButtons: [UInt32: TimeInterval] = [:]

    init() {
        if let romURL {
            let check = GameSession.check(romURL: romURL)
            romOK = check.ok
            romProblem = check.ok || check.message.isEmpty ? nil : check.message
        }
    }

    var romReady: Bool { romURL != nil }

    func importROM(from url: URL) {
        do {
            romURL = try GameSession.importROM(from: url)
            romOK = true
            romProblem = nil
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Starts the game if it is not running yet. Returns false on failure.
    @discardableResult
    func startGame() -> Bool {
        if let session {
            session.paused = false
            return true
        }

        guard let romURL else {
            errorMessage = "Choose your \(GameSession.romSetName) ROM set first."
            return false
        }

        do {
            let s = try GameSession.start(romURL: romURL)
            s.setVolume(volume)
            s.setRenderer(scale: renderScale)
            session = s
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func pauseGame() { session?.paused = true }

    /// Power-cycles the game, as switching the cab off and on: a new session
    /// (the old one saves its settings as it goes).
    func resetGame() {
        guard session != nil else { return }
        session = nil
        gear = 1
        startGame()
    }

    // MARK: Buttons

    /// A momentary press, long enough for the game to latch it.
    func tap(_ button: UInt32, seconds: TimeInterval = 0.15) {
        heldButtons[button] = ProcessInfo.processInfo.systemUptime + seconds
    }

    func shift(_ delta: Int32) { gear = min(4, max(1, gear + delta)) }

    // MARK: Performance log

    private var lastPerformanceLog: TimeInterval = 0

    /// Every few seconds, a line in the console of how fast the game runs and
    /// where a frame's time goes (`where`: the cab, or the screen and its shape;
    /// `width`: the frames' width in pixels).
    func logPerformance(_ place: String, width: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPerformanceLog >= 5 else { return }
        lastPerformanceLog = now

        let renderer = renderScale == 0 ? "CPU" : "GPU \(renderScale)x"
        let t = frameTimes
        print(String(format: "PERF %@ · %@ · %dpx wide · %.1f fps · game %.2f ms · draw %.2f ms · CRT %.2f ms",
                     place, renderer, width, fps, t.game, t.draw, t.crt))
    }

    /// Buttons still held at `now`.
    func panelButtons(now: TimeInterval) -> UInt32 {
        var mask: UInt32 = 0
        for (button, until) in heldButtons {
            if until > now { mask |= button } else { heldButtons[button] = nil }
        }
        return mask
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
