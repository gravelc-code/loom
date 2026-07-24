import Foundation

/// The tonal vocabulary: keys, scales, diatonic chords.

public enum Scale: String, CaseIterable, Codable, Sendable {
    case minor, dorian, phrygian, major, mixolydian, lydian

    /// Semitone offsets from the root.
    public var intervals: [Int] {
        switch self {
        case .major:      return [0, 2, 4, 5, 7, 9, 11]
        case .minor:      return [0, 2, 3, 5, 7, 8, 10]
        case .dorian:     return [0, 2, 3, 5, 7, 9, 10]
        case .phrygian:   return [0, 1, 3, 5, 7, 8, 10]
        case .mixolydian: return [0, 2, 4, 5, 7, 9, 10]
        case .lydian:     return [0, 2, 4, 6, 7, 9, 11]
        }
    }
}

public let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

/// Seed-stream tags so each subsystem draws from its own deterministic stream.
enum Tag {
    static let phrase: UInt64 = 0x5048_5253
    static let wander: UInt64 = 0x574E_4452
    static let chordColor: UInt64 = 0x4348_4F52
    static let journey: UInt64 = 0x4A52_4E59
    static let journeyLen: UInt64 = 0x4A4C_454E
}

/// One leg of the key journey: the sounding key/scale for a run of phrases.
/// Region 0 is always the home key; boundaries land only on phrase starts;
/// after two consecutive regions away, the walk returns home.
public struct JourneyRegion: Sendable, Equatable {
    public let index: Int
    public let startBar: Int
    public let key: Int
    public let scale: Scale

    public init(index: Int, startBar: Int, key: Int, scale: Scale) {
        self.index = index
        self.startBar = startBar
        self.key = key
        self.scale = scale
    }
}

/// A chord expressed as pitch classes over a diatonic root.
public struct Chord: Equatable, Sendable {
    /// Diatonic degree of the root (0-based, 0 = tonic).
    public let degree: Int
    /// Pitch classes (0–11), root first. Includes extensions when present.
    public let pitchClasses: [Int]
    /// Roman-numeral-ish label for display.
    public let label: String

    public var rootPC: Int { pitchClasses[0] }
}

public struct HarmonyContext: Sendable {
    public let key: Int            // pitch class of tonic
    public let scale: Scale
    public let chord: Chord
    public let nextChord: Chord
    /// True for every pitch class present in the scale.
    public let scaleMask: [Bool]   // 12 entries
    /// Scale ∪ current-chord pitch classes — the legal set for pitched
    /// voices. Non-diatonic chord tones (a V7's leading tone, blues 7ths)
    /// are lawful while they sound.
    public let latticeMask: [Bool] // 12 entries

    // Phrase position, so voices can lean into structure.
    public let barInPhrase: Int
    public let phraseBars: Int
    /// Bars into the current chord step (0 on the change bar).
    public let barInChord: Int
    /// Bars left in the current chord step, counting this bar.
    public let chordBarsRemaining: Int
    /// Duration in bars of every step of the current phrase.
    public let phraseStepBars: [Int]
    public let isChordChangeBar: Bool
    public let nextBarIsChordChange: Bool
    public let cadence: Cadence
    public let phraseName: String
    /// Every chord of the current phrase in order (`chord` is
    /// `phraseChords[stepIndex]`) — lets the chord voice re-derive its
    /// voice-leading chain from the phrase start, statelessly.
    public let phraseChords: [Chord]
    public let stepIndex: Int
    /// The key-journey region index (doubles as the movement index) and the
    /// global phrase index (even = antecedent, odd = consequent).
    public let regionIndex: Int
    public let phraseIndex: Int
    /// Absolute position inside the current antecedent/consequent pair.
    /// Internal form machinery uses this to start a theme exactly at a pair
    /// boundary even when the two phrases have different lengths.
    let barInPhrasePair: Int

    /// The consonant-by-construction pitch pool: 5–7 pitch classes, priority
    /// ordered (tonic first), every one lawful against the drone and against
    /// each other. Loose timing over the pool is free harmony — this is the
    /// Eno principle. `pool ⊆ lattice` by construction, so the constraint
    /// pass never moves a pool note.
    public let pool: [Int]
    public let poolMask: [Bool]    // 12 entries

    /// Snap a MIDI note to the nearest scale tone.
    public func snapToScale(_ note: Int) -> Int {
        snap(note, to: scaleMask)
    }

    /// Snap a MIDI note to the nearest lattice (scale ∪ chord) tone.
    public func snapToLattice(_ note: Int) -> Int {
        snap(note, to: latticeMask)
    }

    private func snap(_ note: Int, to mask: [Bool]) -> Int {
        if mask[((note % 12) + 12) % 12] { return note }
        for d in 1...6 {
            if mask[(((note - d) % 12) + 12) % 12] { return note - d }
            if mask[(((note + d) % 12) + 12) % 12] { return note + d }
        }
        return note
    }

    /// Snap a MIDI note to the nearest pool tone.
    public func snapToPool(_ note: Int) -> Int {
        snap(note, to: poolMask)
    }

    /// Build the pitch pool for one chord. Candidates are accepted in
    /// priority order; a candidate is rejected if it is off-lattice, a
    /// semitone from any accepted pitch class, or a tritone from one while
    /// tension is low. The tonic and its 5th are accepted first and always
    /// survive, so everything in the pool is consonant against the drone and
    /// chord changes read as pool rotation.
    public static func buildPool(key: Int, scale: Scale, chord: Chord,
                                 tension: Double, latticeMask: [Bool]) -> [Int] {
        var pool: [Int] = []
        func accept(_ pc: Int, force: Bool = false) {
            let p = ((pc % 12) + 12) % 12
            guard !pool.contains(p) else { return }
            if !force {
                guard latticeMask[p] else { return }
                for q in pool {
                    let d = min((p - q + 12) % 12, (q - p + 12) % 12)
                    if d == 1 { return }
                    if d == 6 && tension < 0.7 { return }
                }
            }
            pool.append(p)
        }
        accept(key)
        accept(key + 7)
        accept(chord.rootPC)
        if chord.pitchClasses.count > 1 { accept(chord.pitchClasses[1]) } // 3rd
        if chord.pitchClasses.count > 2 { accept(chord.pitchClasses[2]) } // 5th
        accept(key + 2)                                                   // 9th
        accept(key + 9)                                                   // 6th
        if chord.pitchClasses.count > 3 { accept(chord.pitchClasses[3]) } // 7th
        // The deliberate dark color: a semitone shadow against the drone,
        // allowed only at high tension and only if the scale contains it.
        if tension >= 0.7 {
            for c in [key + 1, key + 8] {
                let p = ((c % 12) + 12) % 12
                var inScale = false
                for iv in scale.intervals where (key + iv) % 12 == p { inScale = true }
                if inScale { accept(p, force: true); break }
            }
        }
        // Fill to at least 5 from scale tones in consonance order, cap at 7.
        for off in [7, 5, 2, 9, 4, 3, 8, 10, 11] where pool.count < 5 {
            let p = (key + off) % 12
            var inScale = false
            for iv in scale.intervals where (key + iv) % 12 == p { inScale = true }
            if inScale { accept(p) }
        }
        return Array(pool.prefix(7))
    }

    /// Snap a MIDI note to the nearest current-chord tone.
    public func snapToChord(_ note: Int) -> Int {
        var best = note, bestDist = Int.max
        for pc in chord.pitchClasses {
            for oct in -1...9 {
                let cand = oct * 12 + pc
                let d = abs(cand - note)
                if d < bestDist { bestDist = d; best = cand }
            }
        }
        return best
    }

    /// MIDI pitch of the given scale degree (degree 0 = tonic).
    public func scalePitch(degree: Int, octave: Int) -> Int {
        let intervals = scale.intervals
        let n = intervals.count
        let octShift = Int(floor(Double(degree) / Double(n)))
        let idx = ((degree % n) + n) % n
        return (octave + octShift) * 12 + key + intervals[idx]
    }
}

/// The harmony engine: a fixed key/scale (the static law) with a progression
/// built from the classic-phrase bank (the evolving law). A deterministic
/// walk from bar 0 chains phrases — filtered by mode family and conductor
/// tension, biased by cadence — so chord changes always land on bar
/// boundaries and every phrase ends the way phrases end. The `wander` knob
/// substitutes functional neighbors on non-cadence steps for variety.
public struct HarmonyEngine {
    public var key: Int
    public var scale: Scale
    private let seededDialect: HarmonicDialect
    public var dialectOverride: HarmonicDialect?
    public var dialect: HarmonicDialect { dialectOverride ?? seededDialect }

    let seed: UInt64

    public init(key: Int, scale: Scale, seed: UInt64) {
        self.key = key
        self.scale = scale
        self.seed = seed
        let dialectSeed = hashSeed(seed, 0x4449_414C)
        // Soul/jazz grammar is intentionally not a random default: without a
        // style selector it too easily turns the whole piece into lounge
        // music. Seeds now favor ambiguous ambience, with cinematic motion
        // as the contrasting minority. Existing saved labels remain valid.
        self.seededDialect = dialectSeed % 10 < 7 ? .ambient : .cinematic
        self.dialectOverride = nil
    }

    /// Derive a home key and scale from the master seed. The tonic is free
    /// across all 12 pitch classes — every voice octave-normalizes from the
    /// pitch class (see `DroneGenerator`/`BassGenerator`), so register holds
    /// wherever the key lands. The scale is weighted toward loom's dark-minor
    /// identity: minor/dorian/phrygian dominate, with the brighter modes a
    /// rarer contrasting minority. A new seed is a new piece with a new home;
    /// user-set key/scale and loaded performances override this afterwards.
    public static func seededHome(seed: UInt64) -> (key: Int, scale: Scale) {
        var rng = RNG(seed: hashSeed(seed, 0x484F_4D45)) // "HOME"
        let key = rng.int(12)
        let scales: [Scale] = [.minor, .dorian, .phrygian, .major, .mixolydian, .lydian]
        let scale = scales[rng.pick([0.40, 0.20, 0.13, 0.11, 0.09, 0.07])]
        return (key, scale)
    }

    /// Everything about the phrase covering one bar.
    struct PhrasePosition {
        let phrase: ProgressionPhrase
        let nextPhrase: ProgressionPhrase
        let phraseIndex: Int
        let startBar: Int
        let pairStartBar: Int
        /// The journey region this phrase sounds in.
        let region: JourneyRegion
        /// The region the *next* phrase will sound in (differs exactly when
        /// the next phrase starts a modulation).
        let nextPhraseRegion: JourneyRegion
    }

    /// Nominal region length in bars (48–96 ≈ 2.5–4.5 min at 84 bpm),
    /// seeded per region index. The actual region snaps to phrase starts.
    func regionLength(_ index: Int) -> Int {
        var rng = RNG(seed: hashSeed(seed, Tag.journeyLen, UInt64(index)))
        return 48 + rng.int(49)
    }

    /// The next leg of the journey. Weighted toward close relations —
    /// relative, subdominant/dominant, parallel, modal recolor — preferring
    /// keys whose scale still contains the old tonic (the drone bridges the
    /// pivot). Two consecutive regions away forces the walk home.
    func regionAfter(_ region: JourneyRegion, startBar: Int, nonHomeRun: Int) -> JourneyRegion {
        let idx = region.index + 1
        if nonHomeRun >= 2 {
            return JourneyRegion(index: idx, startBar: startBar, key: key, scale: scale)
        }
        var rng = RNG(seed: hashSeed(seed, Tag.journey, UInt64(idx)))
        let k = region.key
        let s = region.scale
        var cands: [(key: Int, scale: Scale, weight: Double)] = []
        if s.modeFamily == .minor {
            cands.append(((k + 3) % 12, .major, 0.3))               // relative major
            cands.append((k, .major, 0.2))                          // parallel major
            cands.append((k, s == .dorian ? .minor : .dorian, 0.2)) // modal recolor
        } else {
            cands.append(((k + 9) % 12, .minor, 0.3))               // relative minor
            cands.append((k, .minor, 0.2))                          // parallel minor
            cands.append((k, s == .lydian ? .major : .lydian, 0.2)) // modal recolor
        }
        cands.append(((k + 5) % 12, s, 0.15))                       // subdominant
        cands.append(((k + 7) % 12, s, 0.15))                       // dominant
        let weights = cands.map { c -> Double in
            var w = c.weight
            // The old tonic surviving in the new scale = a bridgeable pivot.
            if c.scale.intervals.contains(where: { (c.key + $0) % 12 == k }) { w *= 1.6 }
            return w
        }
        let pick = cands[rng.pick(weights)]
        return JourneyRegion(index: idx, startBar: startBar, key: pick.key, scale: pick.scale)
    }

    /// Deterministic phrase walk from bar 0 (one weighted pick per phrase —
    /// cheap) so any bar is randomly accessible and a seed replays the whole
    /// progression. The key-journey region walk rides along: when the bars
    /// accumulated in a region pass its nominal length, the next phrase
    /// begins the next region (so modulations always land on phrase starts,
    /// and the phrase bank family follows the region's scale).
    /// `tensionAt` samples the conductor at each phrase start.
    func phrasePosition(atBar bar: Int, tensionAt: (Int) -> Double) -> PhrasePosition {
        var rng = RNG(seed: hashSeed(seed, Tag.phrase))
        var region = JourneyRegion(index: 0, startBar: 0, key: key, scale: scale)
        var nonHomeRun = 0
        var regionLen = regionLength(0)
        var start = 0
        var index = 0
        var pairStart = 0
        var phrase = pickPhrase(&rng, family: region.scale.modeFamily,
                                tension: tensionAt(0), previous: nil)
        func advanceRegion(to newStart: Int) {
            region = regionAfter(region, startBar: newStart, nonHomeRun: nonHomeRun)
            nonHomeRun = (region.key == key && region.scale == scale) ? 0 : nonHomeRun + 1
            regionLen = regionLength(region.index)
        }
        while bar >= start + phrase.bars {
            start += phrase.bars
            index += 1
            if index.isMultiple(of: 2) { pairStart = start }
            if start - region.startBar >= regionLen { advanceRegion(to: start) }
            phrase = pickPhrase(&rng, family: region.scale.modeFamily,
                                tension: tensionAt(start), previous: phrase)
        }
        // Peek the next phrase (and whether it starts the next region).
        let nextStart = start + phrase.bars
        var peekRegion = region
        if nextStart - region.startBar >= regionLen {
            peekRegion = regionAfter(region, startBar: nextStart, nonHomeRun: nonHomeRun)
        }
        var nextRNG = rng
        let next = pickPhrase(&nextRNG, family: peekRegion.scale.modeFamily,
                              tension: tensionAt(nextStart), previous: phrase)
        return PhrasePosition(phrase: phrase, nextPhrase: next, phraseIndex: index,
                              startBar: start, pairStartBar: pairStart,
                              region: region, nextPhraseRegion: peekRegion)
    }

    /// The journey region sounding at a bar (for the UI and checks).
    public func journeyRegion(atBar bar: Int, tensionAt: (Int) -> Double) -> JourneyRegion {
        phrasePosition(atBar: bar, tensionAt: tensionAt).region
    }

    func pickPhrase(_ rng: inout RNG, family: ModeFamily, tension: Double,
                    previous: ProgressionPhrase?) -> ProgressionPhrase {
        let pool = ProgressionBank.eligible(family: family, tension: tension, dialect: dialect)
        let weights = pool.map { phrase -> Double in
            var w = phrase.weight
            // Cadence chaining: after a phrase that pulls home, prefer one
            // that opens on the tonic; avoid immediate exact repeats a bit.
            if let prev = previous {
                if (prev.cadence == .authentic || prev.cadence == .half),
                   phrase.steps.first?.degree == 0 { w *= 3 }
                if prev.name == phrase.name { w *= 0.4 }
            }
            return w
        }
        return pool[rng.pick(weights)]
    }

    /// The phrase's steps with wander substitutions applied. Seeded per
    /// (phraseIndex, step) so any bar is randomly accessible; the final
    /// (cadence) step is never substituted.
    func substitutedSteps(of phrase: ProgressionPhrase, phraseIndex: Int,
                          wander: Double) -> [ProgressionStep] {
        guard wander > 0 else { return phrase.steps }
        var steps = phrase.steps
        for i in 0..<(steps.count - 1) {
            var rng = RNG(seed: hashSeed(seed, Tag.wander, UInt64(phraseIndex), UInt64(i)))
            guard rng.chance(wander * 0.6) else { continue }
            let d = ((steps[i].degree % 7) + 7) % 7
            let subs = ProgressionBank.substitutions[d]
            steps[i] = ProgressionStep(subs[rng.int(subs.count)], steps[i].bars, .diatonic)
        }
        return steps
    }

    /// Measured chromaticism (the grit-scaled `chromaticism` level): with a low,
    /// tension-weighted chance, turn a short internal step into a secondary
    /// dominant of the step it precedes — a chromatic V7/x that pulls into the
    /// next chord. Never the phrase opener or its cadence, so the backbone and
    /// its resolution are untouched; `chromaticism = 0` returns the steps
    /// unchanged, so grit-zero stays strictly diatonic. Pure per (phrase, step).
    func appliedDominants(_ steps: [ProgressionStep], phraseIndex: Int,
                          chromaticism: Double) -> [ProgressionStep] {
        guard chromaticism > 0, steps.count > 2 else { return steps }
        var out = steps
        for i in 1..<(steps.count - 1) {
            guard steps[i].bars <= 2, steps[i].applied == nil else { continue }
            // Seed on (phrase, step) only — never per-bar tension — so the whole
            // step is a V7/x or none: the substitution stays stable across the
            // step's bars, and a chord label still changes only on change bars.
            var rng = RNG(seed: hashSeed(seed, 0x4150_5044, UInt64(phraseIndex), UInt64(i))) // "APPD"
            guard rng.chance(chromaticism * 0.22) else { continue } // measured: seasoning, not a rule
            out[i] = ProgressionStep(steps[i].degree, steps[i].bars, .dominant7,
                                     applied: steps[i + 1].degree)
        }
        return out
    }

    /// Build the chord for a step in a given key/scale (the journey region's,
    /// not necessarily home). Quality hints force classic colors (dominant
    /// 7ths etc.); plain diatonic steps get probabilistic tension-driven
    /// 7th/9th/sus color as before, seeded per chord change.
    func resolveChord(_ step: ProgressionStep, tension: Double, rng: inout RNG,
                      key: Int, scale: Scale) -> Chord {
        let iv = scale.intervals
        let n = iv.count
        func pc(_ deg: Int) -> Int {
            (key + iv[((deg % n) + n) % n]) % 12
        }
        let numeralsAll = ["i", "ii", "iii", "iv", "v", "vi", "vii"]
        // Secondary dominant: a chromatic V7 whose root is a fifth above the
        // target degree's root, resolving down a fifth into it. Its major third
        // is the target's leading tone — chromatic, lawful only while it sounds.
        if let target = step.applied {
            let root = (pc(target) + 7) % 12
            let pcs = [root, (root + 4) % 12, (root + 7) % 12, (root + 10) % 12]
            let tname = numeralsAll[((target % n) + n) % n]
            return Chord(degree: step.degree, pitchClasses: pcs, label: "V7/\(tname)")
        }
        let degree = step.degree
        var pcs = [pc(degree), pc(degree + 2), pc(degree + 4)]
        var suffix = ""
        switch step.quality {
        case .dominant7:
            pcs[1] = (pcs[0] + 4) % 12
            pcs[2] = (pcs[0] + 7) % 12
            pcs.append((pcs[0] + 10) % 12)
            suffix = "7"
        case .minor7:
            pcs[1] = (pcs[0] + 3) % 12
            pcs.append((pcs[0] + 10) % 12)
            suffix = "7"
        case .sus4:
            pcs[1] = (pcs[0] + 5) % 12
            suffix = "sus4"
        case .diatonic:
            let suspend = dialect == .ambient && tension < 0.62
                || (dialect == .cinematic && tension < 0.38 && rng.chance(0.55))
            if suspend {
                // Remove the defining third. Root + scale-second + fifth is
                // harmonically legible but refuses the cheerful/sad answer
                // that makes a triadic progression sound pre-packaged.
                pcs = [pc(degree), pc(degree + 1), pc(degree + 4)]
                suffix = "sus2"
            } else {
                if rng.chance(tension * 0.45) { pcs.append(pc(degree + 6)); suffix = "7" }
                if rng.chance(tension * 0.18) { pcs.append(pc(degree + 8)); suffix += "9" }
                if suffix.isEmpty && rng.chance(tension * 0.28) {
                    pcs[1] = pc(degree + 3); suffix = "sus4"
                }
            }
        }
        let numerals = ["i", "ii", "iii", "iv", "v", "vi", "vii"]
        let third = (pcs[1] - pcs[0] + 12) % 12
        var name = numerals[((degree % n) + n) % n]
        if third == 4 { name = name.uppercased() }
        return Chord(degree: degree, pitchClasses: pcs, label: name + suffix)
    }

    /// Harmony context for one bar: which chord sounds, what comes next, and
    /// where in the phrase we are.
    public func context(atBar bar: Int, tension: Double, wander: Double,
                        tensionAt: (Int) -> Double, chromaticism: Double = 0) -> HarmonyContext {
        let pos = phrasePosition(atBar: bar, tensionAt: tensionAt)
        let steps = appliedDominants(
            substitutedSteps(of: pos.phrase, phraseIndex: pos.phraseIndex, wander: wander),
            phraseIndex: pos.phraseIndex, chromaticism: chromaticism)
        let barInPhrase = bar - pos.startBar

        var stepStart = 0
        var stepIdx = 0
        for (i, s) in steps.enumerated() {
            if barInPhrase < stepStart + s.bars { stepIdx = i; break }
            stepStart += s.bars
            stepIdx = i
        }
        let step = steps[stepIdx]
        let isChange = barInPhrase == stepStart
        let nextBarIsChange = barInPhrase + 1 == stepStart + step.bars || barInPhrase + 1 == pos.phrase.bars

        // Resolve every chord of the phrase (color-seeded per step). Color
        // tension is sampled at each step's *start* bar — `tension` arrives as
        // an affine blend of the conductor's value at `bar`, so shifting it by
        // the conductor delta re-anchors the blend at the step start. The delta
        // coefficient must equal the conductor weight in the caller's chord
        // tension (Engine: `cond.tension * 0.68 + grit * …`); otherwise a per-bar
        // residual survives and a held chord's color flickers within the step —
        // visible only once grit pushes the baseline near a color threshold.
        var starts: [Int] = []
        var acc = 0
        for s in steps { starts.append(acc); acc += s.bars }
        func colorTension(atStepStart startBar: Int) -> Double {
            max(0, min(1, tension + 0.68 * (tensionAt(pos.startBar + startBar) - tensionAt(bar))))
        }
        let rKey = pos.region.key
        let rScale = pos.region.scale
        let phraseChords = steps.enumerated().map { i, s -> Chord in
            var rng = RNG(seed: hashSeed(seed, Tag.chordColor,
                                         UInt64(pos.phraseIndex), UInt64(i)))
            return resolveChord(s, tension: colorTension(atStepStart: starts[i]), rng: &rng,
                                key: rKey, scale: rScale)
        }
        let chord = phraseChords[stepIdx]

        let nextStep: ProgressionStep
        let nextSeed: (UInt64, UInt64)
        let nextStart: Int
        let nextRegion: JourneyRegion
        if stepIdx + 1 < steps.count {
            nextStep = steps[stepIdx + 1]
            nextSeed = (UInt64(pos.phraseIndex), UInt64(stepIdx + 1))
            nextStart = starts[stepIdx + 1]
            nextRegion = pos.region
        } else {
            let nextSteps = substitutedSteps(of: pos.nextPhrase,
                                             phraseIndex: pos.phraseIndex + 1, wander: wander)
            nextStep = nextSteps[0]
            nextSeed = (UInt64(pos.phraseIndex + 1), 0)
            nextStart = pos.phrase.bars
            nextRegion = pos.nextPhraseRegion // the pivot, if one is coming
        }
        var nextRNG = RNG(seed: hashSeed(seed, Tag.chordColor, nextSeed.0, nextSeed.1))
        let next = resolveChord(nextStep, tension: colorTension(atStepStart: nextStart),
                                rng: &nextRNG, key: nextRegion.key, scale: nextRegion.scale)

        var scaleMask = [Bool](repeating: false, count: 12)
        for iv in rScale.intervals { scaleMask[(rKey + iv) % 12] = true }
        var lattice = scaleMask
        for pc in chord.pitchClasses { lattice[pc] = true }

        let pool = HarmonyContext.buildPool(key: rKey, scale: rScale, chord: chord,
                                            tension: tension, latticeMask: lattice)
        var poolMask = [Bool](repeating: false, count: 12)
        for pc in pool { poolMask[pc] = true }

        let barInChord = barInPhrase - stepStart
        return HarmonyContext(key: rKey, scale: rScale, chord: chord, nextChord: next,
                              scaleMask: scaleMask, latticeMask: lattice,
                              barInPhrase: barInPhrase, phraseBars: pos.phrase.bars,
                              barInChord: barInChord,
                              chordBarsRemaining: step.bars - barInChord,
                              phraseStepBars: steps.map(\.bars),
                              isChordChangeBar: isChange,
                              nextBarIsChordChange: nextBarIsChange,
                              cadence: pos.phrase.cadence, phraseName: pos.phrase.name,
                              phraseChords: phraseChords, stepIndex: stepIdx,
                              regionIndex: pos.region.index, phraseIndex: pos.phraseIndex,
                              barInPhrasePair: bar - pos.pairStartBar,
                              pool: pool, poolMask: poolMask)
    }

    /// The maximal run of consecutive phrases sharing an opening root — the
    /// harmonic floor the drone holds. Spans tile the timeline with no gaps
    /// and are capped at 16 bars so note-offs stay within a schedulable
    /// horizon. Pure function of (seed, bar, wander, tension curve).
    public func droneSpan(atBar bar: Int, wander: Double,
                          tensionAt: (Int) -> Double) -> DroneSpan {
        func openingPC(_ phrase: ProgressionPhrase, _ index: Int,
                       _ region: JourneyRegion) -> Int {
            let deg = substitutedSteps(of: phrase, phraseIndex: index, wander: wander)[0].degree
            let iv = region.scale.intervals
            return (region.key + iv[((deg % iv.count) + iv.count) % iv.count]) % 12
        }
        // Walk phrases well past `bar` so the span containing it is closed —
        // the exact same walk (rng stream + region logic) as phrasePosition.
        var rng = RNG(seed: hashSeed(seed, Tag.phrase))
        var region = JourneyRegion(index: 0, startBar: 0, key: key, scale: scale)
        var nonHomeRun = 0
        var regionLen = regionLength(0)
        var start = 0
        var index = 0
        var phrase = pickPhrase(&rng, family: region.scale.modeFamily,
                                tension: tensionAt(0), previous: nil)
        var walked: [(start: Int, bars: Int, pc: Int)] = []
        while start <= bar + 20 {
            walked.append((start, phrase.bars, openingPC(phrase, index, region)))
            start += phrase.bars
            index += 1
            if start - region.startBar >= regionLen {
                region = regionAfter(region, startBar: start, nonHomeRun: nonHomeRun)
                nonHomeRun = (region.key == key && region.scale == scale) ? 0 : nonHomeRun + 1
                regionLen = regionLength(region.index)
            }
            phrase = pickPhrase(&rng, family: region.scale.modeFamily,
                                tension: tensionAt(start), previous: phrase)
        }
        var spans: [DroneSpan] = []
        for p in walked {
            if let last = spans.last, last.rootPC == p.pc, last.bars + p.bars <= 16 {
                spans[spans.count - 1] = DroneSpan(startBar: last.startBar,
                                                  bars: last.bars + p.bars, rootPC: last.rootPC)
            } else {
                spans.append(DroneSpan(startBar: p.start, bars: p.bars, rootPC: p.pc))
            }
        }
        return spans.first { bar >= $0.startBar && bar < $0.startBar + $0.bars }
            ?? DroneSpan(startBar: bar, bars: 4, rootPC: key)
    }
}

/// A run of bars the drone holds as one breath: root pitch class plus extent.
public struct DroneSpan: Sendable, Equatable {
    public let startBar: Int
    public let bars: Int
    public let rootPC: Int

    public init(startBar: Int, bars: Int, rootPC: Int) {
        self.startBar = startBar
        self.bars = bars
        self.rootPC = rootPC
    }
}
