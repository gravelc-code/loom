import Foundation

/// The piece's feel identity: seeded, role-asymmetric micro-timing applied
/// on top of the correlated Feel noise. Real grooves aren't zero-mean —
/// the kick anchors, the snare lays back, the hats push (or drag — each
/// piece decides once), the bass sits behind the kick, texture percussion
/// is a little drunk. Derived from the voice sub-seed, so `mutate` re-rolls
/// the feel of unlocked voices and a locked voice keeps its pocket.
public struct GrooveSignature {
    let snareLate: Double
    let hatLean: Double
    let percDrunk: Double
    let bassLate: Double
    let chordLate: Double
    let melodyLean: Double
    let drunkNoise: ValueNoise

    public init(seed: UInt64) {
        var rng = RNG(seed: hashSeed(seed, 0x4752_5656))
        snareLate = rng.range(0.02, 0.09)
        hatLean = rng.range(-0.05, 0.02)
        percDrunk = rng.range(0.02, 0.06)
        bassLate = rng.range(0.02, 0.08)
        chordLate = rng.range(0.01, 0.05)
        melodyLean = rng.range(-0.04, 0.04)
        drunkNoise = ValueNoise(seed: hashSeed(seed, 0x4452_4B))
    }

    /// Push/pull in steps for one event. `absoluteStep` feeds the drunk
    /// wobble so texture hits stagger rather than shift uniformly.
    public func offset(voice: Voice, drumNote: Int?, tension: Double,
                       absoluteStep: Double) -> Double {
        switch voice {
        case .drone:  return 0                    // the fixed point stays fixed
        case .bass:   return bassLate
        case .chords: return chordLate
        case .melody: return melodyLean
        case .pulse:  return chordLate * 0.6
        case .drums:
            switch drumNote {
            case 36:     return 0                    // kick anchors the grid
            case 38, 39: return snareLate            // snare/clap lay back
            case 37:     return snareLate * 0.6      // side-stick shares the pocket
            case 42, 46: return hatLean              // hats push or drag
            default:
                let wobble = drunkNoise.value(absoluteStep * 0.7)
                return wobble * percDrunk * (tension < 0.6 ? 2.2 : 1.2)
            }
        }
    }
}

/// Correlated humanize — never `rand()`. One shared "feel" walk per voice
/// fans out to both micro-timing and velocity with a fixed relationship, so
/// they move together: when a voice leans late it also leans soft, the way a
/// player's feel drifts as one gesture.
public struct Feel {
    let noise: ValueNoise
    let jitter: ValueNoise

    public init(seed: UInt64, voice: Voice) {
        let idx = UInt64(Voice.allCases.firstIndex(of: voice)!)
        noise = ValueNoise(seed: hashSeed(seed, 0x4645_454C, idx))
        jitter = ValueNoise(seed: hashSeed(seed, 0x4A49_54, idx))
    }

    /// The feel value at an absolute step time: slow drift plus a small
    /// per-event component, both deterministic.
    public func value(atStep t: Double) -> Double {
        noise.value(t / 24.0) * 0.7 + jitter.value(t * 1.7) * 0.3
    }

    /// Apply to an event in place. `amount` is the voice's humanize param.
    public func apply(to event: inout NoteEvent, absoluteStep: Double, amount: Double) {
        let f = value(atStep: absoluteStep)
        // Up to ~1/10 step of displacement at full humanize (≈ 8 ms at 120bpm).
        event.timingOffset += f * amount * 0.11
        let velScale = 1.0 + f * amount * 0.28
        event.velocity = min(127, max(1, Int(Double(event.velocity) * velScale)))
    }
}
