import Foundation

/// Meso-scale evolution: a bank of slow, normalized sources routed onto voice
/// parameters. All time-based sources are randomly accessible functions of
/// bar time (see `ValueNoise`), so `seed + t` reproduces the performance.
public enum ModSource: String, CaseIterable, Sendable {
    case lfo1, lfo2          // musical-rate LFOs
    case walk1, walk2        // bounded random walks (smoothed noise)
    case pink                // 1/f drift for organic long-term movement
    case field1, field2      // probes into the reaction-diffusion field
    case follower            // activity follower (overall density, reactive)
}

public struct ModRouting: Sendable {
    public let source: ModSource
    public let destination: ParamID
    public let depth: Double
    public init(_ source: ModSource, _ destination: ParamID, _ depth: Double) {
        self.source = source
        self.destination = destination
        self.depth = depth
    }
}

/// Curated routing set (the design doc's open question resolved toward
/// "fixed, well-chosen routings behind the drift / evolution-rate knobs").
/// The full matrix type is here for when a routing UI arrives.
public func defaultRoutings() -> [ModRouting] {
    [
        // Drums breathe: density and swing under slow movement; ghosts,
        // ratchets and fills ride the field so they emerge from the simulation.
        ModRouting(.lfo1,   ParamID(.drums, "density"), 0.18),
        ModRouting(.pink,   ParamID(.drums, "swing"),   0.10),
        ModRouting(.field1, ParamID(.drums, "ghost"),   0.25),
        ModRouting(.field2, ParamID(.drums, "density"), 0.10),

        // Bass: breathing density, approach and follow/syncopation wander.
        ModRouting(.pink,   ParamID(.bass, "density"),   0.08),
        ModRouting(.lfo2,   ParamID(.bass, "density"),   0.15),
        ModRouting(.walk1,  ParamID(.bass, "density"),   0.10),

        // Chords: voicing/color drift so the progression never voices
        // identically twice.
        ModRouting(.walk2,  ParamID(.chords, "register"), 0.18),
        ModRouting(.field1, ParamID(.chords, "register"), 0.08),

        // Pulse: movement breathes, but recurrence keeps the cell legible.
        ModRouting(.lfo1,   ParamID(.pulse, "density"),  0.14),
        ModRouting(.field2, ParamID(.pulse, "gate"),     0.08),
        ModRouting(.walk1,  ParamID(.pulse, "gate"),     0.12),

        // Melody: range and contour wander; the follower thins the melody
        // when drums intensify (reactive behaviour).
        ModRouting(.walk2,    ParamID(.melody, "register"), 0.22),
        ModRouting(.pink,     ParamID(.melody, "register"), 0.10),
        ModRouting(.field2,   ParamID(.melody, "register"), 0.08),
        ModRouting(.follower, ParamID(.melody, "rest"),    0.25),
        // Halved: sparse ambient drives the follower low, which was inflating
        // melody density; loop firing ignores density anyway.
        ModRouting(.follower, ParamID(.melody, "density"), -0.10),

        // Drone register and swell breathe on the slowest sources; binary
        // layer switches never move behind the user's back.
        ModRouting(.pink,   ParamID(.drone, "register"), 0.10),
        ModRouting(.lfo2,   ParamID(.drone, "swell"), 0.20),
    ]
}

public final class ModulationEngine {
    let seed: UInt64
    public let field: Field
    public var routings: [ModRouting]

    /// Set by the engine after each bar: overall event density 0...1,
    /// smoothed — the activity follower.
    public var activity: Double = 0

    // LFO periods in bars, chosen from the seed so every piece breathes at
    // its own rate.
    let lfoPeriod1: Double
    let lfoPeriod2: Double
    let lfoPhase1: Double
    let lfoPhase2: Double

    public init(seed: UInt64) {
        self.seed = seed
        self.field = Field(seed: seed)
        self.routings = defaultRoutings()
        var rng = RNG(seed: hashSeed(seed, 0x4C46_4F))
        lfoPeriod1 = [4.0, 6, 8, 12][rng.pick([1, 1, 1, 1])]
        lfoPeriod2 = [8.0, 12, 16, 24][rng.pick([1, 1, 1, 1])]
        lfoPhase1 = rng.unit()
        lfoPhase2 = rng.unit()
    }

    /// Per-voice noise streams for `link`: link = 1 → all voices ride the
    /// same walk (move together); link = 0 → fully independent wander.
    func noiseSeed(_ tag: UInt64, voice: Voice, link: Double, rng: inout RNG) -> ValueNoise {
        ValueNoise(seed: hashSeed(seed, tag, UInt64(Voice.allCases.firstIndex(of: voice)!)))
    }

    /// Value of a source at bar-time `t` (already scaled by evolution rate),
    /// for a given voice (voices differ where `link` < 1).
    public func value(_ source: ModSource, t: Double, voice: Voice, link: Double) -> Double {
        func blended(_ tag: UInt64, _ eval: (ValueNoise) -> Double) -> Double {
            let shared = eval(ValueNoise(seed: hashSeed(seed, tag)))
            let idx = UInt64(Voice.allCases.firstIndex(of: voice)!) &+ 1
            let own = eval(ValueNoise(seed: hashSeed(seed, tag, idx)))
            return shared * link + own * (1 - link)
        }
        switch source {
        case .lfo1:
            return sin(2 * .pi * (t / lfoPeriod1 + lfoPhase1))
        case .lfo2:
            return sin(2 * .pi * (t / lfoPeriod2 + lfoPhase2))
        case .walk1:
            return blended(0x574B_31) { $0.value(t / 3.0) }
        case .walk2:
            return blended(0x574B_32) { $0.value(t / 5.0) }
        case .pink:
            return blended(0x504B) { $0.fractal(t / 16.0) }
        case .field1:
            return field.sample(x: 0.23 + 0.02 * sin(t * 0.11), y: 0.31)
        case .field2:
            return field.sample(x: 0.71, y: 0.62 + 0.02 * sin(t * 0.07))
        case .follower:
            return activity * 2 - 1
        }
    }

    /// Total modulation offset for one parameter at bar-time `t`.
    /// `depthScale` folds in per-voice drift and the conductor's mod depth.
    public func offset(for param: ParamID, t: Double, link: Double, depthScale: Double) -> Double {
        var sum = 0.0
        for r in routings where r.destination == param {
            sum += r.depth * value(r.source, t: t, voice: param.voice, link: link)
        }
        return sum * depthScale
    }

    /// Advance the field once per bar. ~10 iterations/bar keeps the pattern
    /// crawling on musical timescales.
    public func stepFieldForBar() {
        field.step(iterations: 10)
    }
}
