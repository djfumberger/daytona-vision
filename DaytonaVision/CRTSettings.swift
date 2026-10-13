import Foundation

/// The screen's look: the CRT shader (CRT.metal), how the texture is
/// sampled, and the glass in front of it. Tuned live from the CRT debug panel
/// and kept between launches.
struct CRTSettings: Codable, Equatable {
    var enabled = true

    /// 0 flat picture .. 1 full scanlines.
    var scanlines: Float = 1

    /// Beam sigma (in scanline heights) at black and at full brightness:
    /// thinner beams leave darker gaps between the lines.
    var minBeam: Float = 0.14
    var maxBeam: Float = 0.3

    /// Horizontal blur sigma, in game pixels.
    var blur: Float = 0.6

    var brightness: Float = 1.0
    var bloom: Float = 0.25

    /// Linear brightness above which parts of the picture glow.
    var bloomThreshold: Float = 0.45

    /// Bloom spread, in game pixels.
    var bloomRadius: Float = 6

    /// An old tube's faults (CRT.metal). Focus going soft towards the
    /// corners: the blur and beams there are up to this much wider again.
    var edgeBlur: Float = 0.8

    /// Red and blue landing beside green, in game pixels: a fixed offset, and
    /// more towards the corners.
    var convergence: Float = 0.25
    var misconvergence: Float = 0.6

    /// Patches of colour towards the corners, from a mask needing degaussing.
    var purity: Float = 0.12

    /// One mip level below full size: softens scanline shimmer, but at some
    /// viewing distances it averages the lines away. Off samples full size only.
    var mipSmoothing = true

    /// The glass shell's opacity: how strongly it shows reflections.
    var glassOpacity: Float = 0.12

    /// How worn the tube is: a starting point for every setting above, picked
    /// in the settings (and tuned from there in the debug panel).
    enum Tube: String, CaseIterable, Codable {
        case none, new, midLife, old

        var title: String {
            switch self {
            case .none: "None"
            case .new: "New"
            case .midLife: "Mid-life"
            case .old: "Old"
            }
        }

        var settings: CRTSettings {
            var s = CRTSettings()
            switch self {
            case .none:
                s.enabled = false
            case .new: // sharp, clean, perfectly converged
                s.scanlines = 0.8
                s.minBeam = 0.2
                s.maxBeam = 0.32
                s.blur = 0.45
                s.bloom = 0.15
                s.bloomThreshold = 0.55
                s.bloomRadius = 5
                s.edgeBlur = 0
                s.convergence = 0
                s.misconvergence = 0
                s.purity = 0
            case .midLife: // the defaults
                break
            case .old: // soft, dimmer, glowing, out of convergence, stained (tuned on the headset)
                s.minBeam = 0.12
                s.maxBeam = 0.34
                s.blur = 0.85
                s.brightness = 0.92
                s.bloom = 0.38
                s.bloomThreshold = 0.4
                s.bloomRadius = 8
                s.edgeBlur = 2.1
                s.convergence = 1.04
                s.misconvergence = 1.5
                s.purity = 0.6
                s.glassOpacity = 0.21
            }
            return s
        }
    }

    /// The settings as JSON (sorted, readable), to copy out.
    var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private static let key = "crtSettings.v2" // v2: new beam defaults, so old tuning is dropped

    /// The saved settings over the defaults: a setting added since they were
    /// saved takes its default, and the rest are kept.
    static func load() -> CRTSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaults = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(CRTSettings()))
                as? [String: Any],
              let merged = try? JSONSerialization.data(withJSONObject: defaults.merging(saved) { $1 }),
              let settings = try? JSONDecoder().decode(CRTSettings.self, from: merged)
        else { return CRTSettings() }

        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
