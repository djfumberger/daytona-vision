import Foundation
import Metal

/// The running game: a thin owner of the C core (DaytonaCore.h). The core is
/// thread-safe, so this is shared freely between the main actor and the audio
/// render callbacks.
final class GameSession: @unchecked Sendable {
    static let romSetName = String(cString: dt_rom_set_name())

    static let screenHeight = Int(DT_SCREEN_HEIGHT)
    /// The original screen's width (widescreen frames are wider).
    static let originalWidth = 496
    /// The widest frame, or a stereo pair (two 496-wide frames stacked).
    static let maxFrameBytes = Int(DT_SCREEN_HEIGHT) * 4 * max(Int(DT_SCREEN_MAX_WIDTH), 496 * 2)

    private let game: OpaquePointer

    private init(game: OpaquePointer) { self.game = game }

    deinit { dt_destroy(game) }

    /// Loads the ROM set and starts the game thread.
    static func start(romURL: URL) throws -> GameSession {
        let saveDir = try saveDirectory()
        seedDefaultSettings(in: saveDir)

        var error = [CChar](repeating: 0, count: 512)
        guard let game = dt_create(romURL.path, saveDir.path, &error, Int32(error.count)) else {
            throw GameError(message: String(cString: error))
        }
        return GameSession(game: game)
    }

    /// Checks every file of a ROM set against the set this build was recompiled from.
    static func check(romURL: URL) -> (ok: Bool, message: String) {
        var message = [CChar](repeating: 0, count: 512)
        let ok = dt_check_rom(romURL.path, &message, Int32(message.count))
        return (ok, String(cString: message))
    }

    var paused: Bool = false {
        didSet { dt_set_paused(game, paused) }
    }

    func setVolume(_ volume: Float) { dt_set_volume(game, volume) }

    func setInput(_ input: DTInput) {
        var input = input
        dt_set_input(game, &input)
    }

    /// Stereo 3D: frames then hold both eyes, stacked (left on top).
    func setStereo(_ on: Bool, depth: Float) { dt_set_stereo(game, on, depth) }

    /// Widescreen: the picture widened to `aspect` (width / height); 0 the original screen.
    func setAspect(_ aspect: Double) { dt_set_aspect(game, Float(aspect)) }

    /// Who draws the picture: 0 the CPU, 1-3 the GPU at that scale.
    func setRenderer(scale: Int) { dt_set_renderer(game, Int32(scale)) }

    /// A frame the GPU drew (see dt_gpu_frame).
    struct GPUFrame {
        let buffer: MTLBuffer
        let width: Int
        let height: Int
        /// Pixels from one row to the next (the width, padded).
        let pitch: Int
        let scale: Int
    }

    /// The newest GPU-drawn frame, if there is one newer than `seq`.
    func gpuFrame(seq: inout UInt64) -> GPUFrame? {
        var buffer: UnsafeMutableRawPointer?
        var w: Int32 = 0, h: Int32 = 0, pitch: Int32 = 0, scale: Int32 = 0
        guard dt_gpu_frame(game, &seq, &buffer, &w, &h, &pitch, &scale), let buffer else { return nil }

        let metal = Unmanaged<MTLBuffer>.fromOpaque(buffer).takeUnretainedValue()
        return GPUFrame(buffer: metal, width: Int(w), height: Int(h), pitch: Int(pitch), scale: Int(scale))
    }

    /// Copies the newest frame into `dst` if it is newer than `seq`.
    func copyFrame(into dst: UnsafeMutableRawPointer, capacity: Int, seq: inout UInt64,
                   width: inout Int, height: inout Int) -> Bool {
        var w: Int32 = 0, h: Int32 = 0
        guard dt_copy_frame(game, dst, Int32(capacity), &seq, &w, &h) else { return false }

        width = Int(w)
        height = Int(h)
        return true
    }

    func readAudio(channel: Int, into out: UnsafeMutablePointer<Float>, frames: Int) {
        dt_audio_read(game, Int32(channel), out, Int32(frames))
    }

    var fps: Double { dt_fps(game) }

    /// Milliseconds a frame takes on the game thread (smoothed): running the
    /// game, and drawing it.
    var frameTimes: (game: Float, draw: Float) {
        var g: Float = 0, d: Float = 0
        dt_frame_times(game, &g, &d)
        return (g, d)
    }

    var error: String? {
        var buf = [CChar](repeating: 0, count: 512)
        return dt_error(game, &buf, Int32(buf.count)) ? String(cString: buf) : nil
    }

    // MARK: Files

    private static func saveDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent(romSetName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Revision A's factory settings are a linked twin cabinet that waits for
    /// a second machine. A bundled single-cabinet EEPROM, when present, is
    /// used for the first run instead (scripts/make_default_eeprom.sh makes it).
    private static func seedDefaultSettings(in dir: URL) {
        let eeprom = dir.appendingPathComponent("ioboard_eeprom.bin")
        guard !FileManager.default.fileExists(atPath: eeprom.path),
              let seed = Bundle.main.url(forResource: "default_eeprom", withExtension: "bin") else { return }

        try? FileManager.default.copyItem(at: seed, to: eeprom)
    }

    /// Where an imported ROM set is kept: Documents/<set>.zip (or .7z).
    static func storedROM() -> URL? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for ext in ["zip", "7z"] {
            let url = docs.appendingPathComponent("\(romSetName).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// Copies a user-picked ROM set into the app's documents.
    static func importROM(from url: URL) throws -> URL {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let ext = url.pathExtension.lowercased() == "7z" ? "7z" : "zip"
        let dest = docs.appendingPathComponent("\(romSetName).\(ext)")
        let staging = docs.appendingPathComponent("import-\(UUID().uuidString).\(ext)")
        try FileManager.default.copyItem(at: url, to: staging)

        let result = check(romURL: staging)
        guard result.ok else {
            try? FileManager.default.removeItem(at: staging)
            throw GameError(message: result.message)
        }

        for old in ["zip", "7z"] {
            try? FileManager.default.removeItem(at: docs.appendingPathComponent("\(romSetName).\(old)"))
        }

        try FileManager.default.moveItem(at: staging, to: dest)
        return dest
    }
}

struct GameError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
