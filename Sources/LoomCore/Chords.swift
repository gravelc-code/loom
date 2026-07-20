import Foundation

/// Polyphonic harmonic bed. Voicings are chord tones only, chained with
/// minimal voice movement from the start of the phrase: common tones hold,
/// the rest step to the nearest available chord tone. The chain is recomputed
/// from the phrase start each bar (≤ a dozen steps), so it stays a pure
/// function of `(seed, bar, params)` — no sequential state.
///
/// The voice is deliberately only a pad: one soft attack per chord change,
/// with common tones tied straight through the change. Rhythmic comping lives
/// on the separate pulse port, so a DAW can give movement and atmosphere
/// independent sound design without creating another harmony.
public struct ChordGenerator {
    /// Register window for voicing search.
    static let low = 48, high = 82

    public static func generate(bar: Int, params: ParamSet, harmony: HarmonyContext,
                                subSeed: UInt64, feel: Feel, tension: Double,
                                ensemble: EnsembleContext) -> [NoteEvent] {
        let register = params["register"]
        let spread = params["spread"]     // close ↔ drop-2
        let center = 48 + Int((register * 24).rounded())

        var rng = RNG(seed: hashSeed(subSeed, 0x4348, UInt64(bar)))
        return swell(bar: bar, params: params, harmony: harmony, tension: tension,
                     ensemble: ensemble, center: center, spread: spread,
                     feel: feel, rng: &rng)
    }

    /// Swell mode: emit only at chord starts (plus a re-swell deep into very
    /// long chords), common tones tied through changes. Statelessness comes
    /// from the recomputable voicing chain: any bar can ask what the previous
    /// step's voicing was and whether a note is already sounding.
    static func swell(bar: Int, params: ParamSet, harmony: HarmonyContext,
                      tension: Double, ensemble: EnsembleContext, center: Int,
                      spread: Double, feel: Feel,
                      rng: inout RNG) -> [NoteEvent] {
        let stepBars = harmony.phraseStepBars[harmony.stepIndex]
        let isChordStart = harmony.barInChord == 0
        let reSwell = harmony.barInChord == 8 && stepBars >= 12
        guard isChordStart || reSwell else { return [] }

        let humanize = params["humanize"]
        let releaseVariation = 0.35
        let reAttack = harmony.barInPhrase == 0     // phrase start re-breathes

        // The pad is the newcomer against already-ringing loop tails — its
        // notes lift an octave off any semitone rub with them.
        let voiced = avoidRubs(spaced(voicedChord(upTo: harmony.stepIndex, in: harmony, center: center),
                                      spread: spread),
                               against: ensemble.ringingLoopNotes)
        // Swells ride the phrase arc: each successive swell in a phrase
        // arrives a touch stronger, and the cadence settles.
        let vel = (35.0 + tension * 25)
            * Dynamics.scaled(Dynamics.phraseArc(barInPhrase: harmony.barInPhrase,
                                                 phraseBars: harmony.phraseBars),
                              amount: 0.7)

        if reSwell {
            // Deep into a very long chord: breathe the voicing again for the
            // remaining bars (the initial emission capped itself at 8 bars).
            let remaining = Double((stepBars - 8) * stepsPerBar) - 0.5
            return voiced.enumerated().map { i, n in
                var e = NoteEvent(voice: .chords, note: n,
                                  velocity: Int(max(1, vel - Double(i) * 3)),
                                  startStep: 0, durationSteps: remaining,
                                  timingOffset: Double(i) * 0.15)
                feel.apply(to: &e, absoluteStep: Double(bar * stepsPerBar), amount: humanize * 0.5)
                return e
            }
        }

        // Chord-start swell with common-tone ties. The previous emission is
        // recomputed exactly — including its own rub avoidance at its bar.
        let prev = harmony.stepIndex > 0
            ? avoidRubs(spaced(voicedChord(upTo: harmony.stepIndex - 1, in: harmony, center: center),
                               spread: spread),
                        against: ensemble.prevChordRinging)
            : []
        var events: [NoteEvent] = []
        for (i, n) in voiced.enumerated() {
            // Tie: already sounding from the previous chord's emission —
            // skip, unless the phrase start re-attacks everything.
            if !reAttack && prev.contains(n) { continue }
            // Hold through this chord plus every following step of the
            // phrase that retains the note, capped at 8 bars (12-bar-plus
            // chords dovetail with the re-swell) and 12 bars overall.
            var totalBars = min(stepBars, 8)
            if stepBars < 12 {
                var j = harmony.stepIndex + 1
                while j < harmony.phraseChords.count && totalBars < 12 {
                    let nextVoicing = spaced(voicedChord(upTo: j, in: harmony, center: center),
                                             spread: spread)
                    guard nextVoicing.contains(n) else { break }
                    totalBars += harmony.phraseStepBars[j]
                    j += 1
                }
            }
            var dur = Double(min(totalBars, 12) * stepsPerBar) - 0.5
            // A small seeded stagger keeps releases organic. Extension only:
            // a tied note never lets go before the change it is carrying.
            dur += releaseVariation * rng.range(0, 8)
            var e = NoteEvent(voice: .chords, note: n,
                              velocity: Int(max(1, vel - Double(i) * 3)),
                              startStep: 0, durationSteps: dur,
                              timingOffset: Double(i) * 0.15) // slow strum
            feel.apply(to: &e, absoluteStep: Double(bar * stepsPerBar), amount: humanize * 0.5)
            events.append(e)
        }
        return events
    }

    /// The close-position voicing for a phrase step: the first chord stacks
    /// around the register center, each later chord moves minimally from the
    /// one before it.
    static func voicedChord(upTo stepIndex: Int, in harmony: HarmonyContext, center: Int) -> [Int] {
        var current = initialVoicing(harmony.phraseChords[0], center: center)
        guard stepIndex > 0 else { return current }
        for i in 1...stepIndex {
            current = led(from: current, to: harmony.phraseChords[i], center: center)
        }
        return current
    }

    /// Stack the chord tones in close position with the root nearest the
    /// register center.
    static func initialVoicing(_ chord: Chord, center: Int) -> [Int] {
        var root = center - ((center - chord.rootPC) % 12 + 12) % 12
        if center - root > 6 { root += 12 }
        var notes = [root]
        var prev = root
        for pc in chord.pitchClasses.dropFirst() {
            var n = prev + ((pc - prev) % 12 + 12) % 12
            if n == prev { n += 12 }
            notes.append(n)
            prev = n
        }
        return notes
    }

    /// Minimal-movement voicing of `chord` given the previous voicing:
    /// enumerate octave placements for each chord tone (all within the
    /// window), score by nearness to the old voices plus register and
    /// spacing penalties, take the best.
    static func led(from prev: [Int], to chord: Chord, center: Int) -> [Int] {
        let pcs = chord.pitchClasses
        var best: [Int] = prev
        var bestScore = Double.infinity

        var placements: [[Int]] = pcs.map { pc in
            var opts: [Int] = []
            var n = low + ((pc - low) % 12 + 12) % 12
            while n <= high { opts.append(n); n += 12 }
            return opts
        }
        // Cap the search: 3 nearest options per voice is plenty.
        for i in placements.indices {
            placements[i] = Array(placements[i].sorted {
                abs($0 - center) < abs($1 - center)
            }.prefix(3))
        }

        func score(_ cand: [Int]) -> Double {
            let sorted = cand.sorted()
            var s = 0.0
            // Chamfer distance to the previous voicing — common tones score 0
            // and get retained automatically.
            for n in sorted { s += Double(prev.map { abs($0 - n) }.min() ?? 0) }
            for p in prev { s += Double(sorted.map { abs($0 - p) }.min() ?? 0) * 0.5 }
            // Register pull.
            let mean = Double(sorted.reduce(0, +)) / Double(sorted.count)
            s += abs(mean - Double(center) - 4) * 1.2
            for i in 1..<sorted.count {
                let gap = sorted[i] - sorted[i - 1]
                if gap == 0 { s += 20 }                 // doubled unison: avoid
                if gap == 1 { s += 30 }                 // sustained semitone cluster: never
                if gap > 14 { s += Double(gap - 14) * 2 } // gaping hole
                if gap < 3 && sorted[i - 1] < 52 { s += Double(3 - gap) * 3 } // low mud
            }
            return s
        }

        func rec(_ i: Int, _ acc: [Int]) {
            if i == pcs.count {
                let sc = score(acc)
                if sc < bestScore { bestScore = sc; best = acc.sorted() }
                return
            }
            for n in placements[i] { rec(i + 1, acc + [n]) }
        }
        rec(0, [])
        return best
    }

    /// Lift any voicing note a semitone from an already-sounding pitch up an
    /// octave (down if out of range) — same pitch class, no rub.
    static func avoidRubs(_ notes: [Int], against sounding: [Int]) -> [Int] {
        guard !sounding.isEmpty else { return notes }
        return notes.map { n in
            var v = n
            var tries = 0
            while sounding.contains(where: { abs($0 - v) == 1 }) && tries < 3 {
                if v + 12 <= 94 { v += 12 } else { v -= 24 }
                tries += 1
            }
            return v
        }
    }

    /// Spread > 0.5 opens the voicing drop-2 style: second voice from the top
    /// drops an octave. Still chord tones only. Every emission then passes a
    /// spacing repair: a 9th (or any color tone) squashed a semitone from its
    /// neighbor gets lifted an octave — a sustained b2 cluster inside the pad
    /// is the fastest way to sound broken.
    static func spaced(_ notes: [Int], spread: Double) -> [Int] {
        var n = notes
        if spread > 0.5, n.count >= 4 {
            n.sort()
            let i = n.count - 2
            if n[i] - 12 >= 44 { n[i] -= 12 }
        }
        n.sort()
        var i = 1
        var repairs = 0
        while i < n.count && repairs < 8 {
            if n[i] - n[i - 1] == 1 {
                if n[i] + 12 <= 94 { n[i] += 12 } else { n[i - 1] -= 12 }
                n.sort()
                i = 1
                repairs += 1
                continue
            }
            i += 1
        }
        return n
    }
}
