import Foundation

/// The voices-play-off-each-other mechanism. Computed once per bar in
/// `Engine.generateBar` before the voice loop and passed to every generator
/// alongside `HarmonyContext`. The rhythmic sketch (anchors / gaps /
/// speaking) is a pure function of `(seed, bar, tension)` — deterministic and
/// randomly accessible, so bar N can recompute bar N−1's sketch for
/// question → answer without any sequential state. The motif cell reference
/// is the one deliberate exception: MotifMemory is already sequential (reset
/// by rewind), and sharing it ensemble-wide is what makes the voices quote
/// each other.
public struct EnsembleContext: Sendable {
    /// Shared rhythmic skeleton: 2–5 accent steps, always including 0. Bass
    /// states these anchors, pulse favours them, and drums derive their
    /// kick/snare relationship from them.
    public let anchors: [Int]
    /// Designated answer windows between anchors — melody speaks IN the gaps.
    public let gaps: [Range<Int>]
    /// The one foreground voice this section (from the conductor).
    public let focus: Voice
    /// Whether the focus voice is actually speaking (dense) this bar.
    public let speaking: Bool
    /// Melody delivered a foreground gesture last bar → this bar answers:
    /// chords/bass respond in the first gap, melody rests up.
    public let prevMelodyGesture: Bool
    /// Ensemble-visible motif material (most recent cell) — bass derives a
    /// root-motion version of its rhythm from it.
    public let motifCell: MotifCell?
    /// The current chord voicing (post spacing repair) — the melody keeps a
    /// whole tone clear of every one of these while they sustain.
    public let chordVoicing: [Int]
    /// Top note of the current chord voicing — the melody's anchor tone.
    public var chordTopNote: Int? { chordVoicing.max() }
    /// The drone's current span root pc — voices sharing its register keep
    /// clear of its tones.
    public let droneRootPC: Int?
    /// The drone's actual sounding pitches this bar (root, 5th, octave as the
    /// params dictate). A high register can lift the drone to ~A2, so a bass
    /// clash must be judged against these absolute pitches, not the pitch class.
    public let droneNotes: [Int]
    /// Absolute pitches of loop tails ringing at this bar's start — the pad
    /// keeps a whole tone clear of what is already sounding.
    public let ringingLoopNotes: [Int]
    /// The same set at the previous chord's start bar, so the tie logic can
    /// recompute exactly what the previous swell emitted.
    public let prevChordRinging: [Int]
    /// Piece-wide theme rhythm for this bar (or the most recent scheduled
    /// cell). The designated echo voice may only filter/accent rhythmic
    /// material it already had; this never supplies new onset candidates.
    public let themeCell: MotifCell?
    public let themeEchoVoice: Voice?

    public init(anchors: [Int], gaps: [Range<Int>], focus: Voice, speaking: Bool,
                prevMelodyGesture: Bool, motifCell: MotifCell?, chordVoicing: [Int],
                droneRootPC: Int? = nil, droneNotes: [Int] = [],
                ringingLoopNotes: [Int] = [],
                prevChordRinging: [Int] = [], themeCell: MotifCell? = nil,
                themeEchoVoice: Voice? = nil) {
        self.anchors = anchors
        self.gaps = gaps
        self.focus = focus
        self.speaking = speaking
        self.prevMelodyGesture = prevMelodyGesture
        self.motifCell = motifCell
        self.chordVoicing = chordVoicing
        self.droneRootPC = droneRootPC
        self.droneNotes = droneNotes
        self.ringingLoopNotes = ringingLoopNotes
        self.prevChordRinging = prevChordRinging
        self.themeCell = themeCell
        self.themeEchoVoice = themeEchoVoice
    }

    /// The per-bar rhythmic sketch, recomputable for any bar.
    public static func sketch(seed: UInt64, bar: Int, tension: Double)
        -> (anchors: [Int], gaps: [Range<Int>], speaking: Bool) {
        var rng = RNG(seed: hashSeed(seed, 0x454E_534D, UInt64(bar)))
        // 2–5 anchors, more at higher tension.
        let count = 2 + rng.pick(tension < 0.4 ? [0.55, 0.35, 0.10, 0.0]
                                               : [0.10, 0.35, 0.35, 0.20])
        var anchors: Set<Int> = [0]
        // The kit needs a backbeat anchor so the snare has a home — faded in
        // probabilistically as tension approaches kit territory, so entering
        // kick/snare find anchors waiting. Both draws are unconditional to
        // keep the RNG stream draw-count-stable across tension.
        let bbSide = rng.chance(0.5)
        if rng.chance(smoothstep01((tension - 0.42) / 0.18)) {
            anchors.insert(bbSide ? 4 : 12)
        }
        var candidates = [8, 4, 12, 10, 6, 14, 2]
        while anchors.count < count && !candidates.isEmpty {
            let weights = candidates.enumerated().map { i, _ in 1.0 / Double(i + 1) }
            anchors.insert(candidates.remove(at: rng.pick(weights)))
        }
        let sorted = anchors.sorted()
        // Gaps: the open windows between anchors (and after the last one),
        // one step clear of the anchor itself.
        var gaps: [Range<Int>] = []
        for (i, a) in sorted.enumerated() {
            let next = i + 1 < sorted.count ? sorted[i + 1] : stepsPerBar
            if next - a > 2 { gaps.append((a + 1)..<next) }
        }
        return (sorted, gaps, rng.chance(0.65))
    }
}
