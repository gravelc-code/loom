import Foundation

/// The Eno phase-drift layer: three persistent loops per sub-seed with
/// pairwise-incommensurate periods (prime step counts), so they never
/// re-sync on musical timescales — the music *is* the drift. Firing is fully
/// random-access: a loop fires wherever `(globalStep − offset) % period == 0`.
/// Pitches are pool indices realized fresh at every firing, so chord changes
/// recolor the loops without the loops knowing.
public struct LoopPattern: Sendable {
    public let periodSteps: Int
    public let offsetSteps: Int
    public let poolIndices: [Int]
    public let octave: Int          // register separation: octaves 4/5/6
    public let durSteps: Double
    public let velocity: Int
    /// Seed for the loop's slow dynamic swell.
    public let breathSeed: UInt64

    /// Fire index if this loop fires exactly at global step `g`.
    public func fireIndex(at g: Int) -> Int? {
        guard g >= offsetSteps, (g - offsetSteps) % periodSteps == 0 else { return nil }
        return (g - offsetSteps) / periodSteps
    }

    /// The pool pitch class this loop sounds for a given firing.
    public func pc(forFire index: Int, pool: [Int]) -> Int {
        pool[poolIndices[index % poolIndices.count] % pool.count]
    }

    /// The pitch class still ringing at global step `g` (the last firing's
    /// tail), or nil once the tail has ended. Pure function — this is what
    /// lets the loops *see* each other for the anti-cluster rule.
    public func ringingPC(at g: Int, pool: [Int]) -> Int? {
        guard !pool.isEmpty, g >= offsetSteps else { return nil }
        let idx = (g - offsetSteps) / periodSteps
        let lastFire = offsetSteps + idx * periodSteps
        guard Double(g - lastFire) < durSteps else { return nil }
        return pc(forFire: idx, pool: pool)
    }

    /// Build the event for one firing. Each loop breathes on its own slow
    /// noise curve (~6-bar timescale), so the layer swells and recedes
    /// instead of sitting at one level. `glide` marks the note exempt from
    /// monophonic overlap trimming — overlapping tails are the point.
    public func event(step: Int, globalStep: Int, pc: Int) -> NoteEvent {
        let breath = 0.8 + 0.35 * (ValueNoise(seed: breathSeed)
            .value(Double(globalStep) / 96.0) * 0.5 + 0.5)
        return NoteEvent(voice: .melody, note: (octave + 1) * 12 + pc,
                         velocity: max(1, min(127, Int(Double(velocity) * breath))),
                         startStep: Double(step),
                         durationSteps: durSteps, glide: true)
    }

    /// The three loops for a melody sub-seed (like drum profiles: persistent
    /// until mutate re-rolls the sub-seed). Period slots are chosen so any
    /// pair is non-multiple.
    public static func bank(subSeed: UInt64) -> [LoopPattern] {
        var rng = RNG(seed: hashSeed(subSeed, 0x4C4F_4F50))
        let slots = [[29, 31, 37], [43, 47, 53], [58, 61, 67]]
        return slots.enumerated().map { i, choices in
            LoopPattern(periodSteps: choices[rng.int(choices.count)],
                        offsetSteps: rng.int(32),
                        poolIndices: (0..<(1 + rng.int(3))).map { _ in rng.int(7) },
                        octave: 4 + i, // 60/72/84 — above bass and chord territory
                        durSteps: rng.range(8, 24),
                        velocity: Int(rng.range(35, 60)),
                        breathSeed: hashSeed(subSeed, 0x4252_5448, UInt64(i)))
        }
    }
}
