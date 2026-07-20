import Foundation

/// Monophonic root-and-movement bass. States the harmony: the root lands on
/// the downbeat of every chord-change bar, beats carry chord tones, and the
/// last onset before a change walks an approach tone into the next root.
/// `follow` blends between "lock to chord tones" and "walk within the scale".
///
/// Tension bands (space is the arrangement):
///   < 0.30       silent — the drone owns the low end (unless bass is focus)
///   0.30 – 0.45  one long root per chord change, just above the drone
///   ≥ 0.45       the moving line, onsets locked to the ensemble anchors and
///                rhythm borrowed from the shared motif cell
public struct BassGenerator {
    public static func generate(bar: Int, params: ParamSet, harmony: HarmonyContext,
                                subSeed: UInt64, feel: Feel, tension: Double,
                                isFocus: Bool, ensemble: EnsembleContext) -> [NoteEvent] {
        if tension < 0.30 && !isFocus { return [] }

        // Deja-vu (Marbles): with probability `recur`, recycle the rhythm
        // and pitch-choice stream of the loop-anchor bar; the choices are
        // re-realized against today's chord and anchors, so the groove locks
        // while the harmony stays current.
        var lenRNG = RNG(seed: hashSeed(subSeed, 0x5245_434C))
        let loopLen = [2, 4, 8][lenRNG.int(3)]
        var recRNG = RNG(seed: hashSeed(subSeed, 0x5245_4355, UInt64(bar)))
        let patternBar = recRNG.chance(params["recur"]) ? bar % loopLen : bar
        var rng = RNG(seed: hashSeed(subSeed, 0x4241_5353, UInt64(patternBar)))

        let arc = Dynamics.scaled(Dynamics.phraseArc(barInPhrase: harmony.barInPhrase,
                                                     phraseBars: harmony.phraseBars),
                                  amount: 0.5)

        if tension < 0.45 {
            // Long-root band: state the change, then get out of the way.
            guard harmony.isChordChangeBar else { return [] }
            let note = harmony.chord.rootPC + 36 // octave 2, above the drone
            // Drone clearance (a sustained low 2nd) is resolved authoritatively
            // in the engine's constraint pass, which owns the bass range and so
            // can lift out of the drone's octave even when every in-range octave
            // of this root would rub.
            let bars = min(harmony.chordBarsRemaining, 4)
            return [NoteEvent(voice: .bass, note: note,
                              velocity: Int(rng.range(55, 70) * arc),
                              startStep: 0,
                              durationSteps: Double(bars * stepsPerBar) - 1)]
        }

        let density = params["density"]
        let octaveParam = params["octave"]
        let glide = params["glide"]
        let accent = params["accent"]
        let follow = params["follow"]
        let approach = params["approach"]

        let baseOctave = 1 + Int((octaveParam * 2).rounded()) // octaves 1–3
        let root = harmony.chord.rootPC + (baseOctave + 1) * 12
        let third = root + (harmony.chord.pitchClasses.count > 1
            ? (harmony.chord.pitchClasses[1] - harmony.chord.rootPC + 12) % 12 : 4)

        // Onsets live ON the shared anchors — the bass states the bar's
        // skeleton by construction. When the ensemble carries a
        // motif cell, the bass borrows its rhythm (the root-motion version):
        // anchors near cell onsets survive, the rest thin out.
        var onsets = ensemble.anchors
        if let cell = ensemble.motifCell, rng.chance(0.7) {
            let augment = rng.chance(0.35) // ×2: the cell at half speed
            let cellSteps = cell.notes.map { augment ? Int(($0.step * 2).rounded()) % stepsPerBar
                                                     : Int($0.step.rounded()) }
            let quoted = onsets.filter { a in cellSteps.contains { abs($0 - a) <= 1 } }
            if quoted.count >= 2 { onsets = quoted }
        }
        // Density thins the anchors (never the downbeat).
        onsets = onsets.filter { $0 == 0 || rng.chance(0.35 + density * 0.65) }
        if onsets.isEmpty { onsets = [0] }
        // A chord change is stated, not implied: force the downbeat.
        if harmony.isChordChangeBar && onsets[0] != 0 { onsets.insert(0, at: 0) }

        var events: [NoteEvent] = []
        var lastDegreeOffset = 0
        for (idx, step) in onsets.enumerated() {
            let globalStep = Double(bar * stepsPerBar + step)
            let isLast = idx == onsets.count - 1
            var note: Int

            if step == 0 && harmony.isChordChangeBar {
                note = root
            } else if isLast && step >= 10 && harmony.nextBarIsChordChange && rng.chance(approach) {
                // Approach tone: step into the next chord's root from a
                // scale tone just below or above.
                var target = harmony.nextChord.rootPC + (baseOctave + 1) * 12
                if target - root > 6 { target -= 12 }
                if root - target > 6 { target += 12 }
                note = harmony.snapToScale(rng.chance(0.6) ? target - 1 : target + 2)
                if note == target { note = harmony.snapToScale(target - 2) }
            } else if step % 4 == 0 || rng.chance(follow) {
                // Beats carry chord tones: root, 5th, octave, 3rd.
                let choice = rng.pick([0.5, 0.22, 0.13, 0.15])
                note = root + [0, 7, 12, third - root][choice]
            } else {
                // Walk within the scale near the previous offset.
                let stepMove = rng.pick([0.1, 0.25, 0.3, 0.25, 0.1]) - 2 // -2...2 degrees
                lastDegreeOffset = max(-4, min(5, lastDegreeOffset + stepMove))
                let rootDegree = nearestDegree(of: harmony.chord.rootPC, in: harmony)
                note = harmony.scalePitch(degree: rootDegree + lastDegreeOffset, octave: baseOctave + 1)
                note = harmony.snapToScale(note)
            }

            // Drone clearance happens in the engine's constraint pass (it owns
            // the bass range), so a chord root sitting a whole step from a
            // high-register drone is lifted out of the mud there.

            // Duration: to next onset (or bar end), slightly detached; glide
            // events overlap into the next note for legato/portamento.
            let nextStep = idx + 1 < onsets.count ? onsets[idx + 1] : stepsPerBar
            let gap = Double(nextStep - step)
            let doGlide = rng.chance(glide) && idx + 1 < onsets.count
            let dur = doGlide ? gap * 1.05 : gap * 0.8

            let accented = step % 4 == 0 && rng.chance(accent)
            let base = accented ? rng.range(96, 120) : rng.range(64, 88)
            var e = NoteEvent(voice: .bass, note: note,
                              velocity: Int(min(127, base * arc)),
                              startStep: Double(step), durationSteps: dur, glide: doGlide)
            feel.apply(to: &e, absoluteStep: globalStep, amount: 0.35)
            events.append(e)
        }
        return events
    }

    /// Scale degree (0-based) whose pitch class matches `pc`, or nearest.
    static func nearestDegree(of pc: Int, in harmony: HarmonyContext) -> Int {
        let iv = harmony.scale.intervals
        for (i, offset) in iv.enumerated() where (harmony.key + offset) % 12 == pc { return i }
        return 0
    }
}
