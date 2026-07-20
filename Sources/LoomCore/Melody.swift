import Foundation

/// One bar of melodic material in scale-degree space, relative to a base
/// degree — so a recalled cell can be re-rooted on the current chord
/// (transposition to harmony is free at realization time).
public struct MotifCell: Sendable {
    public struct N: Sendable {
        public var step: Double      // onset within the bar
        public var degree: Int       // scale-degree offset from cell base
        public var dur: Double
        public var vel: Double       // 0...1
    }
    public var notes: [N]
    public var id: Int               // for the motif-memory UI strip

    func transformed(_ t: MotifTransform, rng: inout RNG) -> MotifCell {
        var c = self
        switch t {
        case .transpose:
            break // re-rooting happens at realization; keep intervals intact
        case .invert:
            c.notes = notes.map { n in var m = n; m.degree = -n.degree; return m }
        case .retrograde:
            let maxEnd = notes.map { $0.step + $0.dur }.max() ?? 16
            c.notes = notes.reversed().map { n in
                var m = n; m.step = max(0, maxEnd - n.step - n.dur); return m
            }.sorted { $0.step < $1.step }
        case .augment:
            c.notes = notes.compactMap { n in
                var m = n; m.step = n.step * 2; m.dur = n.dur * 2
                return m.step < 16 ? m : nil
            }
        case .fragment:
            guard notes.count > 2 else { break }
            let half = rng.chance(0.5) ? Array(notes.prefix(notes.count / 2))
                                       : Array(notes.suffix(notes.count / 2))
            let shift = half.first?.step ?? 0
            var frag = half.map { n in var m = n; m.step = n.step - shift; return m }
            // Echo the fragment in the second half of the bar.
            let echoStart = 8.0
            frag += frag.compactMap { n in
                var m = n; m.step = n.step + echoStart; m.vel *= 0.8
                return m.step < 16 ? m : nil
            }
            c.notes = frag
        }
        return c
    }
}

public enum MotifTransform: String, CaseIterable, Sendable {
    case transpose, invert, retrograde, augment, fragment
}

/// Ring buffer of recent melodic cells. Recurrence with variation is what
/// the ear hears as intention — this is the melody's development engine.
public final class MotifMemory {
    public private(set) var cells: [MotifCell] = []
    /// Log for the UI strip: per bar, the recalled cell id (nil = fresh).
    public private(set) var recallLog: [(bar: Int, cellID: Int?, transform: MotifTransform?)] = []
    let capacity = 8
    var nextID = 1
    /// Which cell opened each phrase — the consequent (answer) phrase
    /// restates its antecedent's opening.
    private var openings: [Int: Int] = [:]
    /// Two-bar phrase themes kept independently of the short recency buffer.
    /// Every fourth phrase pair can therefore make a recognizable return even
    /// after its individual cells would otherwise have aged out.
    private var phraseThemes: [Int: [Int: MotifCell]] = [:]

    public init() {}

    func noteOpening(phraseIndex: Int, cellID: Int) {
        openings[phraseIndex] = cellID
    }

    func openingCell(forPhrase index: Int) -> MotifCell? {
        guard let id = openings[index] else { return nil }
        return cells.first { $0.id == id }
    }

    func noteThemeCell(phraseIndex: Int, barInPhrase: Int, cell: MotifCell) {
        guard barInPhrase < 2 else { return }
        phraseThemes[phraseIndex, default: [:]][barInPhrase] = cell
        if phraseThemes.count > 12, let oldest = phraseThemes.keys.min() {
            phraseThemes.removeValue(forKey: oldest)
        }
    }

    func themeCell(forPhrase phraseIndex: Int, barInPhrase: Int) -> MotifCell? {
        phraseThemes[phraseIndex]?[barInPhrase]
    }

    /// Movement boundary: let the oldest themes go — the new key gets room
    /// for new material while the freshest cells carry across the pivot.
    public func fade() {
        // A movement begins a new thematic chapter. Recent cells bridge the
        // modulation, while the long-form reprise archive starts clean.
        phraseThemes.removeAll()
        guard cells.count > 1 else { return }
        cells.removeFirst(cells.count / 2)
    }

    func store(_ cell: MotifCell) -> MotifCell {
        var c = cell
        c.id = nextID
        nextID += 1
        cells.append(c)
        if cells.count > capacity { cells.removeFirst() }
        return c
    }

    func log(bar: Int, cellID: Int?, transform: MotifTransform?) {
        recallLog.append((bar, cellID, transform))
        if recallLog.count > 64 { recallLog.removeFirst() }
    }

    /// Full motif state, for the display lookahead's snapshot/restore.
    struct State {
        var cells: [MotifCell]
        var recallLog: [(bar: Int, cellID: Int?, transform: MotifTransform?)]
        var openings: [Int: Int]
        var phraseThemes: [Int: [Int: MotifCell]]
        var nextID: Int
    }
    func captureState() -> State {
        State(cells: cells, recallLog: recallLog, openings: openings,
              phraseThemes: phraseThemes, nextID: nextID)
    }
    func restore(_ s: State) {
        cells = s.cells; recallLog = s.recallLog; openings = s.openings
        phraseThemes = s.phraseThemes; nextID = s.nextID
    }

    public func reset() {
        cells.removeAll()
        recallLog.removeAll()
        openings.removeAll()
        phraseThemes.removeAll()
        nextID = 1
    }
}

/// The lead voice — where "musically complete over time" is won or lost.
///
/// Two personalities crossfaded by tension:
///   < 0.35       one faint, intermittent phase loop
///   0.35 – 0.55  the loop, plus occasional motif bars
///   ≥ 0.55       motif gestures become more likely, never continuous
/// Motif bars choose between fresh material and recalling + transforming an
/// earlier cell, governed by `motif recurrence`.
public struct MelodyGenerator {
    public static func generate(bar: Int, params: ParamSet, harmony: HarmonyContext,
                                subSeed: UInt64, bankSeed: UInt64, feel: Feel,
                                memory: MotifMemory, recurrence: Double, tension: Double,
                                ensemble: EnsembleContext) -> [NoteEvent] {
        let lenScale = lengthScale(params["length"])
        let durationVariation = 0.35
        let density = params["density"]
        var rest = params["rest"]

        // The phase-drift loops fire regardless of the motif machinery.
        // Anti-cluster rule: what sustains together must be consonant
        // together. Before a loop fires, it checks the other loops' ringing
        // tails (pure functions — fully recomputable): if the chosen pitch
        // class is a step away (1–2 semitones) from a ringing one, walk the
        // pool for a substitute that clears; if nothing clears, the firing
        // is skipped — silence is ambient-correct.
        // The bank seed carries the movement salt: a new key journey region
        // brings a fresh loop vocabulary (unless the voice is locked).
        let loops = LoopPattern.bank(subSeed: bankSeed)
        // One line is enough. Multiple long phase loops made the layer read
        // as a second, permanently talking melody rather than atmosphere.
        let activeLoops = [loops[0]]
        let pool = harmony.pool
        var loopEvents: [NoteEvent] = []
        // Absolute pitches of loop tails ringing anywhere in this bar — the
        // motif line will keep a whole tone clear of them too.
        var ringingLoopNotes = Set<Int>()
        for p in activeLoops {
            if let pc = p.ringingPC(at: bar * stepsPerBar, pool: pool) {
                let raw = (p.octave + 1) * 12 + pc
                ringingLoopNotes.insert(harmony.snapToChord(raw))
            }
        }
        if !pool.isEmpty {
            for step in 0..<stepsPerBar {
                let g = bar * stepsPerBar + step
                for (li, p) in activeLoops.enumerated() {
                    guard let fire = p.fireIndex(at: g) else { continue }
                    // The phase line is punctuation: high `rest` also thins
                    // it, using a random-access seed so rendering is stable.
                    var gate = RNG(seed: hashSeed(subSeed, 0x4C50_4741,
                                                 UInt64(g), UInt64(li)))
                    guard gate.chance(0.42 + (1 - rest) * 0.42) else { continue }
                    let ringing = activeLoops.enumerated().compactMap { lj, q -> Int? in
                        lj == li ? nil : q.ringingPC(at: g, pool: pool)
                    }
                    func clashes(_ pc: Int) -> Bool {
                        let clashesLoops = ringing.contains { r in
                            let d = min((pc - r + 12) % 12, (r - pc + 12) % 12)
                            return d == 1
                        }
                        // The pad is already sounding — a new firing must
                        // not land a semitone from a sustained chord voice.
                        let note = (p.octave + 1) * 12 + pc
                        let clashesChords = ensemble.chordVoicing.contains { abs($0 - note) == 1 }
                        return clashesLoops || clashesChords
                    }
                    // A sustaining phase note belongs to the current chord.
                    // Color tones are for brief passing motion, not a long
                    // note arguing with the pad underneath it.
                    let rawPC = p.pc(forFire: fire, pool: pool)
                    let orderedChordPCs = harmony.chord.pitchClasses.sorted {
                        let da = min(($0 - rawPC + 12) % 12, (rawPC - $0 + 12) % 12)
                        let db = min(($1 - rawPC + 12) % 12, (rawPC - $1 + 12) % 12)
                        return da < db
                    }
                    let pc = orderedChordPCs.first { !clashes($0) }
                    guard let chosen = pc else { continue }
                    var m = p.event(step: step, globalStep: g, pc: chosen)
                    var vr = RNG(seed: hashSeed(subSeed, 0x4C56_5259, UInt64(g)))
                    let toChordBoundary = Double(harmony.chordBarsRemaining * stepsPerBar - step) - 0.25
                    let shapedDuration = m.durationSteps * lenScale
                        * (1 + durationVariation * vr.range(-0.5, 1.0))
                    m.durationSteps = max(0.5, min(min(8, toChordBoundary), shapedDuration))
                    m.velocity = max(1, Int(Double(m.velocity) * 0.64))
                    loopEvents.append(m)
                    ringingLoopNotes.insert(m.note)
                }
            }
        }

        // Band crossfade: is this a motif bar at all?
        let motifBar: Bool
        var bandRNG = RNG(seed: hashSeed(subSeed, 0x424E_4400, UInt64(bar)))
        if tension >= 0.55 {
            motifBar = bandRNG.chance(0.42 + min(0.18, (tension - 0.55) * 0.4))
        } else if tension >= 0.35 {
            motifBar = bandRNG.chance(((tension - 0.35) / 0.2) * 0.42)
        } else {
            motifBar = false
        }
        guard motifBar else {
            memory.log(bar: bar, cellID: nil, transform: nil)
            return loopEvents
        }

        let register = params["register"]
        let motion = params["motion"]
        let repeatT = params["repeat"]
        let contour = params["contour"]
        let glide = params["glide"]
        let humanize = params["humanize"]

        // Phrase climax: a foreground phrase builds to a registral high point
        // near its golden section and settles after — the long-line shape that
        // reads as composed rather than as per-bar noodling. The arc lifts the
        // realization register and leans a fresh line toward the crest; motif
        // recalls keep their own contour but ride the same register arc.
        let (peakBar, peakHeight) = phraseClimax(phraseBars: harmony.phraseBars,
                                                 subSeed: subSeed,
                                                 phraseIndex: harmony.phraseIndex,
                                                 tension: tension)
        let climaxArc = climaxShape(barInPhrase: harmony.barInPhrase, peakBar: peakBar,
                                    phraseBars: harmony.phraseBars)
        let climaxLift = Int((peakHeight * climaxArc.height).rounded())
        let arcContour = min(1, max(0, contour + climaxArc.slope * 0.3))

        // Question → answer: after a foreground gesture, leave more space.
        if ensemble.prevMelodyGesture { rest = min(1, rest + 0.25) }

        var rng = RNG(seed: hashSeed(subSeed, 0x4D454C, UInt64(bar)))

        // Whole-bar rest is a musical event too.
        if rng.chance(0.18 + rest * 0.55) {
            memory.log(bar: bar, cellID: nil, transform: nil)
            return loopEvents
        }

        let cell: MotifCell
        var recalledID: Int? = nil
        var transform: MotifTransform? = nil
        let isOpening = harmony.barInPhrase == 0
        let isReprisePair = harmony.phraseIndex >= 4 && harmony.phraseIndex % 4 < 2
        if isReprisePair,
           let theme = memory.themeCell(forPhrase: harmony.phraseIndex - 4,
                                        barInPhrase: harmony.barInPhrase) {
            // A two-bar theme returns one phrase-pair later. Re-rooting in the
            // current harmony makes it recognizably the same thought in a new
            // place rather than a pasted MIDI loop.
            cell = theme
            recalledID = theme.id
            transform = .transpose
        } else if isOpening, harmony.cadence != .none, harmony.phraseIndex % 2 == 1,
           let question = memory.openingCell(forPhrase: harmony.phraseIndex - 1),
           rng.chance(0.85) {
            // Consequent phrase: the answer opens like the question — a
            // near-exact restatement (re-rooted in the current harmony),
            // destined to cadence home where the question stayed open.
            cell = question
            recalledID = question.id
            transform = .transpose
        } else if !memory.cells.isEmpty && rng.chance(recurrence) {
            // Recall + transform: prefer recent cells slightly.
            let idx = memory.cells.count - 1 - rng.pick((0..<memory.cells.count).map { Double($0 + 1) })
            let t = MotifTransform.allCases[rng.pick([0.3, 0.15, 0.15, 0.15, 0.25])]
            let source = memory.cells[max(0, min(memory.cells.count - 1, idx))]
            cell = source.transformed(t, rng: &rng)
            recalledID = source.id
            transform = t
        } else {
            let fresh = freshCell(rng: &rng, density: density, rest: rest, motion: motion,
                                  repeatT: repeatT, contour: arcContour)
            cell = memory.store(fresh)
        }
        // Fresh bars log the new cell's id with no transform; recalls log the
        // source id plus how it was transformed; rests logged nil/nil above.
        memory.log(bar: bar, cellID: recalledID ?? cell.id, transform: transform)
        memory.noteThemeCell(phraseIndex: harmony.phraseIndex,
                             barInPhrase: harmony.barInPhrase, cell: cell)
        if isOpening { memory.noteOpening(phraseIndex: harmony.phraseIndex, cellID: recalledID ?? cell.id) }

        // Realize in the current harmony: root the cell on a chord tone near
        // the register the `range` knob asks for — but always ABOVE the top
        // of the chord voicing. The melody lives over the bed, never inside
        // it (a line threading through the pad's register rubs seconds
        // against sustained chord tones). The cell's degrees are offsets
        // from a *linear* scale degree (octaves folded in), so the contour
        // realizes in the intended register.
        var center = 52 + Int((register * 30).rounded()) + climaxLift
        if let top = ensemble.chordTopNote {
            center = max(center, top + 5)
        }
        var base = harmony.snapToScale(harmony.snapToChord(center))
        if let top = ensemble.chordTopNote, base < top + 3 { base += 12 }
        let baseDegree = linearDegree(of: base, in: harmony)

        let lastBarOfPhrase = harmony.barInPhrase == harmony.phraseBars - 1
        let sorted = cell.notes.sorted(by: { $0.step < $1.step })
        let dynamics = params["dynamics"]
        let peakDegree = sorted.map(\.degree).max()
        let arc = Dynamics.scaled(Dynamics.phraseArc(barInPhrase: harmony.barInPhrase,
                                                     phraseBars: harmony.phraseBars),
                                  amount: dynamics)

        var events: [NoteEvent] = []
        for (i, n) in sorted.enumerated() {
            var pitch = harmony.scalePitch(degree: baseDegree + n.degree, octave: 0)
            // The chord is gravity. Only a short weak note bracketed by
            // stepwise motion may leave it; everything sustained or exposed
            // is a chord tone, so melody and pad read as one composition.
            let metricStrong = n.step.truncatingRemainder(dividingBy: 4) == 0
            let stepFromPrevious = i > 0 && abs(n.degree - sorted[i - 1].degree) == 1
            let stepToNext = i + 1 < sorted.count
                && abs(sorted[i + 1].degree - n.degree) == 1
            let passing = !metricStrong && n.dur <= 0.75
                && stepFromPrevious && stepToNext
            let strong = !passing
            pitch = passing ? harmony.snapToPool(pitch) : harmony.snapToChord(pitch)
            // Rub avoidance: a non-passing note a semitone from a sustained
            // pad voice or ringing loop tail moves to the nearest lawful
            // pitch that clears — passing tones are brief enough to rub.
            if !passing {
                pitch = clearRub(pitch, against: ensemble.chordVoicing + ringingLoopNotes,
                                 strong: strong, harmony: harmony)
            }

            // Call and response: the anchors belong to bass/pulse — nudge a
            // motif onset off an anchor into the adjacent gap when one is
            // right there.
            var step = n.step
            let intStep = Int(step.rounded(.down))
            if intStep != 0 && ensemble.anchors.contains(intStep)
                && ensemble.gaps.contains(where: { $0.contains(intStep + 1) }) {
                step += 1
            }

            var dur = max(0.4, n.dur * lenScale
                          * (1 + durationVariation * rng.range(-0.5, 1.0)))
            let toChordBoundary = Double(harmony.chordBarsRemaining * stepsPerBar) - step - 0.25
            dur = min(dur, max(0.4, toChordBoundary))
            if passing { dur = min(dur, 0.75) }
            let isCadential = harmony.cadence != .none
                && lastBarOfPhrase && i == sorted.count - 1
            // Cadential targeting with question/answer grammar: an
            // antecedent (even phrase) ends OPEN on the 3rd or 5th; a
            // consequent (odd phrase) closes HOME on the root and holds it.
            if isCadential {
                let pcs = harmony.chord.pitchClasses
                let targets: [Int] = harmony.phraseIndex % 2 == 1
                    ? [pcs[0]]
                    : (pcs.count > 2 ? [pcs[1], pcs[2]] : Array(pcs.prefix(2)))
                var best = pitch, bestDist = Int.max
                for pc in targets {
                    for oct in 3...7 {
                        let cand = oct * 12 + pc
                        if abs(cand - pitch) < bestDist { bestDist = abs(cand - pitch); best = cand }
                    }
                }
                pitch = clearRub(best, against: ensemble.chordVoicing + ringingLoopNotes,
                                 strong: true, harmony: harmony)
                dur = max(dur, Double(stepsPerBar) - step)
            }

            // Shaped velocity: the cell's gesture × metric accent × phrase
            // arc, the bar's melodic peak leans forward, and the cadential
            // resolution settles rather than lands loud.
            var vel = (40 + n.vel * 70)
                * Dynamics.scaled(Dynamics.metricAccent(step: step), amount: dynamics)
                * arc
            if step == 0 || step == 8 { vel *= 1 + dynamics * 0.12 }
            else if step.rounded() == step && Int(step) % 2 == 1 {
                vel *= 1 - dynamics * 0.08
            }
            if n.degree == peakDegree { vel += 6 * dynamics }
            if isCadential { vel *= 1 - 0.08 * dynamics }

            var e = NoteEvent(voice: .melody, note: pitch,
                              velocity: Int(min(127, max(1, vel))),
                              startStep: step, durationSteps: dur,
                              glide: rng.chance(glide))
            feel.apply(to: &e, absoluteStep: Double(bar * stepsPerBar) + step, amount: humanize)

            // Ornament: at rising tension, occasionally approach a note with
            // a soft grace a scale step away, a 16th-quarter early.
            if tension >= 0.5, step >= 0.5, rng.chance(motion * 0.25) {
                var gp = harmony.snapToScale(pitch + (rng.chance(0.5) ? 2 : -1))
                if gp == pitch { gp = harmony.snapToScale(pitch - 2) }
                events.append(NoteEvent(voice: .melody, note: gp,
                                        velocity: max(1, Int(vel * 0.4)),
                                        startStep: step - 0.25, durationSteps: 0.3))
            }
            events.append(e)
        }
        return loopEvents + events
    }

    /// Move a pitch off a semitone rub against any of `sounding`. Candidates
    /// are the lawful set for the position (chord tones when strong, pool
    /// tones otherwise) realized in nearby octaves; the nearest clearing
    /// candidate wins. If nothing clears, the original stands.
    static func clearRub(_ pitch: Int, against sounding: [Int], strong: Bool,
                         harmony: HarmonyContext) -> Int {
        func rubs(_ p: Int) -> Bool { sounding.contains { abs($0 - p) == 1 } }
        guard rubs(pitch) else { return pitch }
        let pcs = strong ? harmony.chord.pitchClasses : harmony.pool
        var candidates: [Int] = []
        for pc in pcs {
            for oct in -1...1 {
                let cand = (pitch / 12 + oct) * 12 + pc
                if abs(cand - pitch) <= 14 { candidates.append(cand) }
            }
        }
        return candidates.filter { !rubs($0) }
            .min(by: { abs($0 - pitch) < abs($1 - pitch) }) ?? pitch
    }

    /// The linear scale degree (octaves included) whose `scalePitch(degree:
    /// octave: 0)` equals `pitch`. `pitch` must be a scale tone.
    static func linearDegree(of pitch: Int, in harmony: HarmonyContext) -> Int {
        let iv = harmony.scale.intervals
        for (idx, offset) in iv.enumerated() {
            let rem = pitch - harmony.key - offset
            if rem % 12 == 0 { return (rem / 12) * iv.count + idx }
        }
        return 0
    }

    /// The registral climax for a foreground phrase: which bar the line peaks
    /// on (near the golden section, with a little seeded wander) and how far it
    /// lifts at the crest, in semitones, growing with tension. Deterministic
    /// per phrase, so a replayed performance arcs identically.
    static func phraseClimax(phraseBars: Int, subSeed: UInt64, phraseIndex: Int,
                             tension: Double) -> (peakBar: Int, height: Double) {
        guard phraseBars > 1 else { return (0, 0) }
        var rng = RNG(seed: hashSeed(subSeed, 0x504B_4C4D, UInt64(max(0, phraseIndex)))) // "PKLM"
        let frac = 0.55 + rng.range(0, 0.22)              // golden-ish, 0.55…0.77
        let peakBar = min(phraseBars - 1, max(1, Int((Double(phraseBars - 1) * frac).rounded())))
        let height = 2.0 + tension * 6.0                  // semitones of lift at the crest
        return (peakBar, height)
    }

    /// The arc's shape at one bar: a raised-cosine `height` in 0…1 that crests
    /// at `peakBar` and vanishes at the phrase edges, plus a `slope` (+1 rising,
    /// −1 falling, 0 at the crest) that leans a fresh line toward the peak.
    static func climaxShape(barInPhrase: Int, peakBar: Int, phraseBars: Int)
        -> (height: Double, slope: Double) {
        guard phraseBars > 1 else { return (0, 0) }
        let pos = Double(barInPhrase)
        let rising = pos <= Double(peakBar)
        let frac: Double
        if rising {
            frac = peakBar == 0 ? 1 : pos / Double(peakBar)
        } else {
            let tail = Double(phraseBars - 1 - peakBar)
            frac = tail <= 0 ? 0 : 1 - (pos - Double(peakBar)) / tail
        }
        let h = (1 - cos(min(1, max(0, frac)) * .pi)) / 2
        let slope = barInPhrase == peakBar ? 0.0 : (rising ? 1.0 : -1.0)
        return (h, slope)
    }

    /// Generate a fresh one-bar cell in degree space.
    static func freshCell(rng: inout RNG, density: Double, rest: Double, motion: Double,
                          repeatT: Double, contour: Double) -> MotifCell {
        var notes: [MotifCell.N] = []
        var degree = 0
        var step = 0.0
        var lastWasLeap = false
        var lastLeapDirection = 0
        // Contour bias: 0 = descending, 0.5 = arch, 1 = ascending.
        let maxNotes = 2 + Int((density * 5).rounded())
        while step < 16 && notes.count < maxNotes {
            // Note or rest?
            if rng.chance(rest * 0.5) {
                step += [1.0, 2.0, 2.0, 4.0][rng.pick([1, 1.5, 1, 0.5])]
                continue
            }
            let dur = [0.5, 1.0, 1.0, 2.0, 3.0, 4.0][rng.pick([density, 1, 1, 1.2 - density, 0.6, 0.4 - density * 0.3].map { max(0.01, $0) })]
            let phase = step / 16.0
            // Direction bias from contour: arch peaks mid-bar.
            let bias: Double
            if contour < 0.33 { bias = -0.5 }
            else if contour > 0.67 { bias = 0.5 }
            else { bias = phase < 0.5 ? 0.6 : -0.6 } // arch
            let prevDegree = degree
            if lastWasLeap {
                // Classical leap recovery: step back the way we came.
                degree += lastLeapDirection > 0 ? -1 : 1
                lastWasLeap = false
            } else if rng.chance(repeatT) {
                // repeat previous pitch
            } else if rng.chance(motion) {
                // Leap — a 3rd or 4th; wider (up to a 6th) only when the
                // motion knob is pushed hard. Singable, not erratic.
                let size = motion > 0.6 ? 2 + rng.int(4) : 2 + rng.int(2)
                let dir = rng.chance(0.5 + bias * 0.4) ? 1 : -1
                degree += size * dir
                lastWasLeap = true
                lastLeapDirection = dir
            } else {
                degree += rng.chance(0.5 + bias * 0.4) ? 1 : -1
            }
            degree = max(-4, min(5, degree)) // about an octave and a third
            // Velocity is part of the gesture, not noise: higher notes carry
            // more weight, leaps arrive with an accent, and only a small
            // seeded wobble on top. Because it lives in the cell, a recalled
            // motif repeats its dynamic shape along with its pitches.
            let leapAccent = abs(degree - prevDegree) >= 2 ? 0.12 : 0.0
            let vel = 0.5 + Double(degree) * 0.025 + leapAccent + rng.range(-0.07, 0.07)
            notes.append(.init(step: step, degree: degree,
                               dur: dur * 0.9, vel: min(0.9, max(0.25, vel))))
            step += dur
        }
        return MotifCell(notes: notes, id: 0)
    }

}
