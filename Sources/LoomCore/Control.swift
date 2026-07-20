import Foundation

/// Continuous-control output: the modulation matrix made MIDI-mappable.
/// Each voice's port carries a small set of CC lanes driven by the same
/// deterministic sources that move the parameters — map them to synth macros
/// in the DAW and the patch breathes with the piece.
public struct CCEvent: Sendable, Equatable {
    public let voice: Voice
    public let controller: Int
    public let value: Int        // 0...127
    public let startStep: Double // grid position within the bar

    public init(voice: Voice, controller: Int, value: Int, startStep: Double) {
        self.voice = voice
        self.controller = controller
        self.value = value
        self.startStep = startStep
    }
}

/// The CC lane map, identical on every voice port:
///   CC 1  — conductor tension (the global arc)
///   CC 20 — field probe 1 (reaction-diffusion texture)
///   CC 21 — LFO 1
///   CC 22 — random walk 2
///   CC 23 — activity follower (overall density)
///   CC 11 — voice-specific musical expression arc
///   CC 74 — brightness / filter-sweep: opens across a build, snaps wide at the
///           drop, closes through a breakdown (map to filter cutoff)
///   CC 25 — riser / transition envelope: rises across the whole build-up, holds
///           through the vacuum, snaps to 0 at the drop (map to a riser / noise)
///   CC 26 — impact / downlifter: a falling envelope over the drop and the fall
///           out of a peak (map to an impact / downlifter FX)
///   CC 27 — space / reverb-wash: swells into vacuums and breakdowns, pulls back
///           in dense peaks (map to a reverb send)
/// The drone port adds one extra lane:
///   CC 24 — drone swell (triangle over the drone span, scaled by `swell`)
public enum ControlLanes {
    public static let tensionController = 1
    public static let expressionController = 11
    public static let swellController = 24
    public static let transitionController = 25
    public static let dropAccentController = 26
    public static let reverbWashController = 27
    public static let brightnessController = 74
    public static let sourceLanes: [(controller: Int, source: ModSource)] = [
        (20, .field1), (21, .lfo1), (22, .walk2), (23, .follower),
    ]

    /// Map a bipolar (-1...1) source value onto 0...127.
    public static func quantize(_ v: Double) -> Int {
        let clamped = min(1, max(-1, v))
        return min(127, max(0, Int(((clamped + 1) * 0.5 * 127).rounded())))
    }

    /// Samples per bar per lane (every 2 steps). The transport layer drops
    /// unchanged values, so the emitted list stays a pure function of the bar.
    public static let samplesPerBar = 8
}
