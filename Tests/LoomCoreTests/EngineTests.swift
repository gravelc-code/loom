import XCTest
@testable import LoomCore

final class EngineTests: XCTestCase {

    func streamDigest(_ engine: Engine, bars: Int, controls: Bool = false) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        func mix(_ value: UInt64) {
            var v = value
            for _ in 0..<8 {
                hash ^= v & 0xff
                hash &*= 0x100000001b3
                v >>= 8
            }
        }
        for bar in 0..<bars {
            let output = engine.generateBar(bar)
            mix(UInt64(bar)); mix(UInt64(output.events.count))
            for event in output.events {
                mix(UInt64(Voice.allCases.firstIndex(of: event.voice)!))
                mix(UInt64(event.note)); mix(UInt64(event.velocity))
                mix(event.startStep.bitPattern); mix(event.durationSteps.bitPattern)
                mix(event.timingOffset.bitPattern); mix(event.glide ? 1 : 0)
            }
            guard controls else { continue }
            mix(UInt64(output.controls.count))
            for event in output.controls {
                mix(UInt64(Voice.allCases.firstIndex(of: event.voice)!))
                mix(UInt64(event.controller)); mix(UInt64(event.value))
                mix(event.startStep.bitPattern)
            }
        }
        return hash
    }

    func testLegacy128BarGoldenDigests() {
        XCTAssertEqual(streamDigest(Engine(seed: 12345, compositionVersion: .legacy), bars: 128),
                       0x3922_e2cb_411e_6142)
        XCTAssertEqual(streamDigest(Engine(seed: 0xC0A1, compositionVersion: .legacy), bars: 128),
                       0x7f00_616f_43dd_d2f4)
    }

    func events(seed: UInt64, bars: Int) -> [[NoteEvent]] {
        let e = Engine(seed: seed)
        e.rewind()
        return (0..<bars).map { e.generateBar($0).events }
    }

    /// An engine with the section clock at its fastest, so 48–96 bars sweep
    /// the whole arc (intro → peak) instead of sitting in a long ambient
    /// intro. Used by tests that need high-tension (kit/motif) bars.
    func fastArcEngine(seed: UInt64) -> Engine {
        let e = Engine(seed: seed)
        e.evolution.sectionLength = 0
        e.rewind()
        return e
    }

    /// A saved seed replays the whole evolving performance identically.
    func testDeterminism() {
        let a = events(seed: 12345, bars: 12)
        let b = events(seed: 12345, bars: 12)
        for bar in 0..<12 {
            XCTAssertEqual(a[bar].count, b[bar].count, "bar \(bar) event count")
            for (x, y) in zip(a[bar], b[bar]) {
                XCTAssertEqual(x.note, y.note)
                XCTAssertEqual(x.velocity, y.velocity)
                XCTAssertEqual(x.startStep, y.startStep, accuracy: 1e-12)
                XCTAssertEqual(x.timingOffset, y.timingOffset, accuracy: 1e-12)
            }
        }
    }

    /// The display lookahead must be truthful: `previewBars` returns exactly the
    /// notes real generation produces at those bars, and restoring afterwards is
    /// exact (real generation continues from the restored state and matches).
    func testPreviewBarsMatchRealGeneration() {
        let e = Engine(seed: 0xF00D); e.rewind()
        let n = 20, k = 6
        for b in 0..<n { _ = e.generateBar(b) }
        let preview = e.previewBars(fromBar: n, count: k)
        var real: [[NoteSummary]] = []
        for b in n..<(n + k) { real.append(e.generateBar(b).snapshot.notes) }
        XCTAssertEqual(preview.count, k)
        for i in 0..<k {
            XCTAssertEqual(preview[i].count, real[i].count, "bar \(n + i) note count")
            for (a, c) in zip(preview[i], real[i]) {
                XCTAssertEqual(a.note, c.note)
                XCTAssertEqual(a.velocity, c.velocity)
                XCTAssertEqual(a.startStep, c.startStep, accuracy: 1e-9)
                XCTAssertEqual(a.durationSteps, c.durationSteps, accuracy: 1e-9)
                XCTAssertEqual(a.voice, c.voice)
            }
        }
    }

    /// A preview must leave zero footprint: an engine that previewed and one that
    /// didn't generate all subsequent bars identically. This catches any
    /// sequential field (especially the reaction-diffusion field and the interest
    /// watchdog) missing from the snapshot.
    func testPreviewLeavesNoFootprint() {
        let a = Engine(seed: 0x1357); a.rewind()
        let b = Engine(seed: 0x1357); b.rewind()
        let n = 16
        for i in 0..<n { _ = a.generateBar(i); _ = b.generateBar(i) }
        _ = a.previewBars(fromBar: n, count: 8)      // a previews; b does not
        for i in n..<(n + 40) {
            let an = a.generateBar(i).snapshot.notes
            let bn = b.generateBar(i).snapshot.notes
            XCTAssertEqual(an.map(\.note), bn.map(\.note), "bar \(i) diverged after preview")
            XCTAssertEqual(an.map(\.velocity), bn.map(\.velocity), "bar \(i) velocities diverged")
        }
    }



    func testSeedsDiffer() {
        let a = events(seed: 1, bars: 8).flatMap { $0 }
        let b = events(seed: 2, bars: 8).flatMap { $0 }
        XCTAssertNotEqual(a.map(\.note), b.map(\.note))
    }

    /// The piece must not stand still: a groove repeats enough to be legible
    /// but develops optional notes over time, and effective params drift.
    func testEvolution() {
        let e = fastArcEngine(seed: 777)
        var drumBars: [[Int]] = []
        var effDensities: [Double] = []
        for bar in 0..<128 {
            let out = e.generateBar(bar)
            if out.snapshot.tension >= 0.65 {
                let hits = out.events.filter { $0.voice == .drums }
                    .map { Int($0.startStep * 8) * 128 + $0.note }
                if !hits.isEmpty { drumBars.append(hits) }
            }
            effDensities.append(out.snapshot.effectiveParams[.drums]!["density"]!)
        }
        XCTAssertGreaterThan(drumBars.count, 4, "fast arc should reach kit-mode bars")
        let uniqueBars = Set(drumBars.map { "\($0)" })
        XCTAssertGreaterThan(uniqueBars.count, max(3, drumBars.count / 5),
                             "the pocket should develop without randomizing its backbone")
        let dMin = effDensities.min()!, dMax = effDensities.max()!
        XCTAssertGreaterThan(dMax - dMin, 0.02, "modulation should move density over the arc")
    }

    /// The harmony context the engine used for a bar (same derivation as
    /// `generateBar`).
    func harmony(of e: Engine, bar: Int) -> HarmonyContext {
        let sectionBars = e.evolution.sectionBars
        let cond = e.conductor.state(bar: bar, sectionBars: sectionBars)
        let chordTension = min(1, cond.tension * 0.68 + e.evolution.grit * 0.18)
        return e.harmonyEngine.context(atBar: bar, tension: chordTension,
                                       wander: e.evolution.wander,
                                       tensionAt: { e.conductor.state(bar: $0, sectionBars: sectionBars).tension },
                                       chromaticism: e.evolution.grit)
    }

    func tension(of e: Engine, bar: Int) -> Double {
        e.conductor.state(bar: bar, sectionBars: e.evolution.sectionBars).tension
    }

    /// Constraint pass: every pitched note lands in the lattice (scale ∪
    /// chord tones); chord-voice notes are chord tones only. The drone is
    /// exempt from the lattice (its 5th above a diminished opener is the one
    /// lawful exception, held by design).
    func testTonalLaw() {
        let e = fastArcEngine(seed: 42)
        for bar in 0..<24 {
            let h = harmony(of: e, bar: bar)
            for ev in e.generateBar(bar).events where ev.voice != .drums && ev.voice != .drone {
                let pc = ((ev.note % 12) + 12) % 12
                XCTAssertTrue(h.latticeMask[pc],
                              "\(ev.voice) note \(ev.note) (pc \(pc)) off-lattice in bar \(bar) (\(h.chord.label))")
                if ev.voice == .chords {
                    XCTAssertTrue(h.chord.pitchClasses.contains(pc) || h.nextChord.pitchClasses.contains(pc),
                                  "chords note \(ev.note) not a chord tone in bar \(bar)")
                }
                XCTAssertTrue((1...127).contains(ev.velocity))
                XCTAssertTrue((0..<16).contains(Int(ev.startStep)))
            }
        }
    }

    /// Drum notes use General MIDI's conventional Ableton-friendly kit pads.
    func testDrumNotesUseStandardKitLayout() {
        XCTAssertEqual(DrumTrack.kick.note, 36)
        XCTAssertEqual(DrumTrack.rim.note, 37)
        XCTAssertEqual(DrumTrack.snare.note, 38)
        XCTAssertEqual(DrumTrack.clap.note, 39)
        XCTAssertEqual(DrumTrack.hat.note, 42)
        XCTAssertEqual(DrumTrack.glitch.note, 43)
        XCTAssertEqual(DrumTrack.perc.note, 45)
        XCTAssertEqual(DrumTrack.hatOpen.note, 46)
        let kitNotes = Set(DrumTrack.allCases.map(\.note))
        let e = fastArcEngine(seed: 7)
        for bar in 0..<48 {
            for ev in e.generateBar(bar).events where ev.voice == .drums {
                XCTAssertTrue(kitNotes.contains(ev.note), "drum note \(ev.note) off the standard map")
            }
        }
    }

    /// Chords change only on chord-change bars.
    func testChordChangesOnBarBoundaries() {
        let e = Engine(seed: 3)
        e.rewind()
        var prev: String? = nil
        for bar in 0..<48 {
            let snap = e.generateBar(bar).snapshot
            if let p = prev, p != snap.chordLabel {
                XCTAssertTrue(snap.isChordChangeBar,
                              "chord changed to \(snap.chordLabel) off a change bar (bar \(bar))")
            }
            prev = snap.chordLabel
        }
    }

    /// With wander = 0 the progression is exactly a bank phrase.
    func testCadencePhraseStructure() {
        let he = HarmonyEngine(key: 0, scale: .minor, seed: 42)
        let flat: (Int) -> Double = { _ in 0.5 }
        let first = he.context(atBar: 0, tension: 0.5, wander: 0, tensionAt: flat)
        let phrase = ProgressionBank.phrases.first {
            $0.name == first.phraseName && $0.modeFamily == .minor
        }
        XCTAssertNotNil(phrase, "phrase \(first.phraseName) not in bank")
        var expected: [Int] = []
        for step in phrase!.steps { expected += Array(repeating: step.degree, count: step.bars) }
        for bar in 0..<phrase!.bars {
            let ctx = he.context(atBar: bar, tension: 0.5, wander: 0, tensionAt: flat)
            XCTAssertEqual(ctx.chord.degree, expected[bar],
                           "bar \(bar) of \(first.phraseName): degree \(ctx.chord.degree) ≠ \(expected[bar])")
        }
    }

    /// Wander substitutes mid-phrase chords but never the cadence step.
    func testWanderPreservesCadence() {
        let he = HarmonyEngine(key: 9, scale: .minor, seed: 99)
        let flat: (Int) -> Double = { _ in 0.5 }
        var checked = 0
        for bar in 0..<128 {
            let pure = he.context(atBar: bar, tension: 0.5, wander: 0, tensionAt: flat)
            guard pure.barInPhrase == pure.phraseBars - 1 else { continue }
            let wandered = he.context(atBar: bar, tension: 0.5, wander: 1.0, tensionAt: flat)
            XCTAssertEqual(pure.chord.degree, wandered.chord.degree,
                           "cadence chord substituted at bar \(bar)")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 3)
    }

    /// Voice leading: chord voicings are chord tones and move minimally
    /// between steps of a phrase.
    func testVoiceLeadingMovement() {
        let e = Engine(seed: 21)
        e.rewind()
        for bar in 0..<32 {
            let h = harmony(of: e, bar: bar)
            let v = ChordGenerator.voicedChord(upTo: h.stepIndex, in: h, center: 60)
            for n in v {
                XCTAssertTrue(h.chord.pitchClasses.contains(((n % 12) + 12) % 12),
                              "voicing note \(n) not a chord tone (\(h.chord.label))")
            }
            if h.stepIndex > 0 {
                let prev = ChordGenerator.voicedChord(upTo: h.stepIndex - 1, in: h, center: 60)
                var total = 0
                for n in v { total += prev.map { abs($0 - n) }.min() ?? 0 }
                XCTAssertLessThanOrEqual(total, 14,
                                         "voicing leapt \(total) semitones: \(prev) → \(v)")
            }
        }
    }

    /// Melody register plus pitch law: the low phase line belongs to the
    /// sounding chord; motif-band exposed notes are chord or pool tones.
    func testMelodyChordTonesAndRegister() {
        let e = fastArcEngine(seed: 13)
        e.evolution.locked[.melody] = true // freeze range/octave knobs
        for bar in 0..<96 {
            let h = harmony(of: e, bar: bar)
            let t = tension(of: e, bar: bar)
            for ev in e.generateBar(bar).events where ev.voice == .melody {
                XCTAssertTrue((55...100).contains(ev.note), "melody note \(ev.note) out of register")
                let pc = ((ev.note % 12) + 12) % 12
                if t < 0.35 {
                    XCTAssertTrue(h.chord.pitchClasses.contains(pc),
                                  "loop-band melody note \(ev.note) (pc \(pc)) not in chord in bar \(bar)")
                } else if t >= 0.55, ev.startStep.truncatingRemainder(dividingBy: 4) == 0 {
                    XCTAssertTrue(h.chord.pitchClasses.contains(pc) || h.poolMask[pc],
                                  "strong-beat melody note \(ev.note) (pc \(pc)) neither chord tone nor pool tone in bar \(bar) (\(h.chord.label))")
                }
            }
        }
    }

    /// The pad is harmonic gravity, while silence is part of the line. Any
    /// note outside the sounding chord must be a brief passing gesture rather
    /// than a competing sustained harmony.
    func testMelodyUsesChordGravityAndSpace() {
        let e = fastArcEngine(seed: 0xC111)
        var noteCount = 0
        var silentBars = 0
        for bar in 0..<160 {
            let h = harmony(of: e, bar: bar)
            let melody = e.generateBar(bar).events.filter { $0.voice == .melody }
            if melody.isEmpty { silentBars += 1 }
            noteCount += melody.count
            for event in melody {
                let pc = ((event.note % 12) + 12) % 12
                if !h.chord.pitchClasses.contains(pc) {
                    XCTAssertLessThanOrEqual(event.durationSteps, 0.8,
                        "non-chord melody note \(event.note) sustains against \(h.chord.label) at bar \(bar)")
                }
            }
        }
        XCTAssertGreaterThan(silentBars, 48, "the melody does not leave enough whole-bar space")
        XCTAssertLessThan(noteCount, 200, "the default melody still talks too much")
    }

    /// Rhythmic movement has its own port, but never its own harmony. The pad
    /// remains a bed while pulse events stay monophonic and chord-locked.
    func testPulseIsChordLockedAndSeparatedFromPad() {
        let e = fastArcEngine(seed: 0x5055_15E)
        e.params[.pulse]?["amount"] = 0.8
        e.evolution.push = 0.72
        var pulseCount = 0
        for bar in 0..<128 {
            let h = harmony(of: e, bar: bar)
            let out = e.generateBar(bar)
            let pulse = out.events.filter { $0.voice == .pulse }
                .sorted { $0.startStep < $1.startStep }
            pulseCount += pulse.count
            for event in pulse {
                let pc = ((event.note % 12) + 12) % 12
                XCTAssertTrue(h.chord.pitchClasses.contains(pc),
                              "pulse \(event.note) left \(h.chord.label) at bar \(bar)")
                XCTAssertTrue((55...92).contains(event.note))
            }
            for i in 0..<max(0, pulse.count - 1) {
                XCTAssertLessThanOrEqual(pulse[i].startStep + pulse[i].durationSteps,
                                         pulse[i + 1].startStep + 0.001,
                                         "pulse became polyphonic at bar \(bar)")
            }
            // Chord events are pad attacks, never short rhythmic stabs.
            for chord in out.events where chord.voice == .chords {
                XCTAssertGreaterThanOrEqual(chord.durationSteps, 2)
            }
        }
        XCTAssertGreaterThan(pulseCount, 20)
    }

    func testPersistedArrangementCues() {
        let e = fastArcEngine(seed: 0xC0E)
        e.evolution.arrangementCues = [
            ArrangementCue(startBar: 4, kind: .buildDrop),
            ArrangementCue(startBar: 20, kind: .breakdown),
        ]
        let sb = e.evolution.sectionBars
        XCTAssertEqual(e.conductor.state(bar: 4, sectionBars: sb,
                                         cues: e.evolution.arrangementCues).event, .build)
        XCTAssertEqual(e.conductor.state(bar: 5, sectionBars: sb,
                                         cues: e.evolution.arrangementCues).event, .build)
        XCTAssertEqual(e.conductor.state(bar: 6, sectionBars: sb,
                                         cues: e.evolution.arrangementCues).event, .vacuum)
        XCTAssertEqual(e.conductor.state(bar: 7, sectionBars: sb,
                                         cues: e.evolution.arrangementCues).event, .drop)
        XCTAssertEqual(e.conductor.state(bar: 20, sectionBars: sb,
                                         cues: e.evolution.arrangementCues).section, .breakdown)

        // The build→drop cue still marks the run-up, but it is gentle now (the
        // kit sustains rather than cutting to silence, and the arrival is a soft
        // lift, not an EDM slam). The cued landing brings the ensemble in.
        let drop = e.generateBar(7)
        XCTAssertTrue(drop.events.contains { $0.voice == .pulse && $0.startStep == 0 })
        XCTAssertGreaterThanOrEqual(Set(drop.events.map(\.voice)).count, 3)
    }

    func testStyleOverridesAndClockPLL() {
        XCTAssertEqual(DrumGenerator.style(profileSeed: 1, override: .broken), .broken)
        let e = Engine(seed: 4)
        e.harmonyEngine.dialectOverride = .cinematic
        XCTAssertEqual(e.harmonyEngine.dialect, .cinematic)

        var pll = MIDIClockPLL()
        let interval = UInt64(20_833_333) // 120 BPM / 24 PPQN in nanoseconds
        for tick in 0..<96 {
            pll.acceptTick(hostTime: UInt64(tick) * interval) { Double($0) / 1e9 }
        }
        XCTAssertEqual(pll.bpm ?? 0, 120, accuracy: 0.1)
        XCTAssertEqual(pll.ticksSinceStart, 96)
    }

    /// Bass states the root on the downbeat of every chord-change bar it
    /// plays in (in the long-root band that is the *only* thing it does).
    func testBassRootOnChanges() {
        let e = fastArcEngine(seed: 17)
        var checked = 0
        for bar in 0..<96 {
            let h = harmony(of: e, bar: bar)
            let bass = e.generateBar(bar).events.filter { $0.voice == .bass }
            guard h.isChordChangeBar, !bass.isEmpty else { continue }
            let down = bass.filter { $0.startStep == 0 }
            XCTAssertFalse(down.isEmpty, "no downbeat bass on change bar \(bar)")
            for d in down {
                XCTAssertEqual(((d.note % 12) + 12) % 12, h.chord.rootPC,
                               "bass downbeat \(d.note) isn't the root of \(h.chord.label) in bar \(bar)")
            }
            checked += 1
        }
        XCTAssertGreaterThan(checked, 3)
    }

    /// CC lanes are deterministic and in range (5 lanes on every voice port
    /// plus the drone's swell lane).
    func testCCLanes() {
        let e1 = Engine(seed: 31); e1.rewind()
        let e2 = Engine(seed: 31); e2.rewind()
        for bar in 0..<8 {
            let a = e1.generateBar(bar).controls
            let b = e2.generateBar(bar).controls
            XCTAssertEqual(a, b, "CC output differs at bar \(bar)")
            XCTAssertLessThanOrEqual(a.count, (5 * 5 + 1) * ControlLanes.samplesPerBar)
            for c in a {
                XCTAssertTrue((0...127).contains(c.value))
                XCTAssertTrue((0..<16).contains(Int(c.startStep)))
            }
        }
    }

    /// The progression must advance: over enough bars, more than one chord.
    func testProgressionAdvances() {
        let e = fastArcEngine(seed: 9)
        var labels = Set<String>()
        for bar in 0..<48 { labels.insert(e.generateBar(bar).snapshot.chordLabel) }
        XCTAssertGreaterThan(labels.count, 2, "harmony should move: got \(labels)")
    }

    /// The conductor must produce a long-form arc: near-silent lows, kit-mode
    /// highs, several distinct sections.
    func testConductorArc() {
        let c = Conductor(seed: 5)
        let tensions = (0..<600).map { c.state(bar: $0, sectionBars: 16).tension }
        XCTAssertLessThan(tensions.min()!, 0.1)
        XCTAssertGreaterThan(tensions.max()!, 0.75)
        let sections = Set((0..<600).map { c.state(bar: $0, sectionBars: 16).section })
        XCTAssertGreaterThanOrEqual(sections.count, 3)
    }

    /// Lock: a locked voice's material survives mutate; unlocked re-rolls.
    func testLockAndMutate() {
        let e1 = Engine(seed: 100)
        e1.evolution.locked[.drums] = true
        let beforeSub = e1.subSeeds[.drums]!
        let beforeBassSub = e1.subSeeds[.bass]!
        e1.mutate()
        XCTAssertEqual(e1.subSeeds[.drums]!, beforeSub, "locked drums keep their sub-seed")
        XCTAssertNotEqual(e1.subSeeds[.bass]!, beforeBassSub, "unlocked bass re-rolls")
    }

    /// Motif memory: with high recurrence the melody recalls earlier cells
    /// once the arc reaches the motif band.
    func testMotifRecall() {
        let e = fastArcEngine(seed: 55)
        e.evolution.motifRecurrence = 0.9
        for bar in 0..<96 { _ = e.generateBar(bar) }
        let recalls = e.motifMemory.recallLog.filter { $0.cellID != nil }
        XCTAssertGreaterThan(recalls.count, 3, "melody should recall motifs at high recurrence")
    }

    // MARK: - v2: drone

    /// Drone events appear only on span-start bars, hold whole spans (≤ 16
    /// bars, minus the one-step breath), sound the span root, and the spans
    /// tile the timeline with no gaps or overlaps.
    func testDroneHoldsPhrases() {
        let e = Engine(seed: 0xD05E)
        e.rewind()
        let sectionBars = e.evolution.sectionBars
        let tensionAt: (Int) -> Double = { e.conductor.state(bar: $0, sectionBars: sectionBars).tension }

        var prevSpan: DroneSpan? = nil
        for bar in 0..<64 {
            let span = e.harmonyEngine.droneSpan(atBar: bar, wander: e.evolution.wander,
                                                 tensionAt: tensionAt)
            XCTAssertLessThanOrEqual(span.bars, 16)
            XCTAssertTrue(bar >= span.startBar && bar < span.startBar + span.bars,
                          "span \(span) does not cover bar \(bar)")
            if let p = prevSpan, p != span {
                XCTAssertEqual(p.startBar + p.bars, span.startBar,
                               "spans must tile: \(p) → \(span)")
            }
            prevSpan = span

            let drone = e.generateBar(bar).events.filter { $0.voice == .drone }
            if bar == span.startBar {
                XCTAssertFalse(drone.isEmpty, "no drone at span start (bar \(bar))")
                for ev in drone {
                    XCTAssertEqual(ev.durationSteps, Double(span.bars * stepsPerBar) - 1,
                                   accuracy: 1e-9, "drone must hold the whole span")
                }
                XCTAssertEqual(((drone[0].note % 12) + 12) % 12, span.rootPC,
                               "drone root pc ≠ span root")
            } else {
                XCTAssertTrue(drone.isEmpty, "drone re-attacked mid-span (bar \(bar))")
            }
        }
    }

    /// CC24 swell: present on the drone port, deterministic, in range, and
    /// actually rising over a span (a triangle, not a flat line).
    func testDroneSwellCC() {
        let e1 = Engine(seed: 71); e1.rewind()
        let e2 = Engine(seed: 71); e2.rewind()
        var swellValues: [Int] = []
        for bar in 0..<16 {
            let a = e1.generateBar(bar).controls.filter {
                $0.voice == .drone && $0.controller == ControlLanes.swellController
            }
            let b = e2.generateBar(bar).controls.filter {
                $0.voice == .drone && $0.controller == ControlLanes.swellController
            }
            XCTAssertEqual(a, b)
            XCTAssertEqual(a.count, ControlLanes.samplesPerBar, "swell lane missing in bar \(bar)")
            for c in a { XCTAssertTrue((0...127).contains(c.value)) }
            swellValues += a.map(\.value)
        }
        XCTAssertGreaterThan(swellValues.max()! - swellValues.min()!, 8,
                             "swell should move across a span")
    }

    // MARK: - v2: pitch pool

    /// Pool law: 5–7 pcs, a subset of the lattice, tonic + 5th always
    /// present, and no semitone pairs at low tension.
    func testPoolConsonance() {
        for scale in Scale.allCases {
            let he = HarmonyEngine(key: 2, scale: scale, seed: 31337)
            for bar in stride(from: 0, to: 96, by: 3) {
                for t in [0.1, 0.4] {
                    let ctx = he.context(atBar: bar, tension: t, wander: 0.3, tensionAt: { _ in t })
                    XCTAssertTrue((5...7).contains(ctx.pool.count),
                                  "\(scale) pool size \(ctx.pool.count) at bar \(bar)")
                    for pc in ctx.pool {
                        XCTAssertTrue(ctx.latticeMask[pc], "pool pc \(pc) off-lattice (\(scale))")
                    }
                    // The pool follows the journey's sounding key.
                    XCTAssertEqual(ctx.pool.first, ctx.key, "tonic must lead the pool")
                    XCTAssertTrue(ctx.pool.contains((ctx.key + 7) % 12), "5th must survive (\(scale))")
                    for a in ctx.pool {
                        for b in ctx.pool where a != b {
                            let d = min((a - b + 12) % 12, (b - a + 12) % 12)
                            XCTAssertNotEqual(d, 1,
                                              "semitone pair \(a)/\(b) in low-tension pool (\(scale))")
                        }
                    }
                }
            }
        }
    }

    /// At flat low tension the ambient bank rules: chords hold ≥ 4 bars on
    /// average.
    func testSlowHarmonicRhythmAtLowTension() {
        let he = HarmonyEngine(key: 9, scale: .minor, seed: 12)
        let bars = 128
        var changes = 0
        for bar in 0..<bars {
            let ctx = he.context(atBar: bar, tension: 0.1, wander: 0, tensionAt: { _ in 0.1 })
            if ctx.isChordChangeBar { changes += 1 }
        }
        XCTAssertGreaterThanOrEqual(Double(bars) / Double(max(1, changes)), 4.0,
                                    "mean chord duration \(Double(bars) / Double(max(1, changes))) < 4 bars")
    }

    // MARK: - v2: ensemble coupling

    /// The rhythmic sketch is deterministic and well-formed.
    func testEnsembleAnchorsDeterministic() {
        for bar in 0..<32 {
            let a = EnsembleContext.sketch(seed: 555, bar: bar, tension: 0.5)
            let b = EnsembleContext.sketch(seed: 555, bar: bar, tension: 0.5)
            XCTAssertEqual(a.anchors, b.anchors)
            XCTAssertEqual(a.gaps, b.gaps)
            XCTAssertEqual(a.speaking, b.speaking)
            XCTAssertTrue(a.anchors.contains(0))
            XCTAssertTrue((2...5).contains(a.anchors.count))
        }
    }

    /// Bass (≥ 0.45) and pad attacks (≥ 0.55) begin on structural
    /// anchors; rhythmic chord motion belongs to the pulse voice.
    func testOnsetsOnAnchors() {
        let e = fastArcEngine(seed: 88)
        var bassChecked = 0, chordChecked = 0
        for bar in 0..<96 {
            let t = tension(of: e, bar: bar)
            let sk = EnsembleContext.sketch(seed: e.masterSeed, bar: bar, tension: t)
            let out = e.generateBar(bar)
            if t >= 0.45 {
                for ev in out.events where ev.voice == .bass {
                    XCTAssertTrue(sk.anchors.contains(Int(ev.startStep)),
                                  "bass onset \(ev.startStep) off-anchor in bar \(bar) (anchors \(sk.anchors))")
                    bassChecked += 1
                }
            }
            if t >= 0.55 {
                for ev in out.events where ev.voice == .chords && ev.startStep < 15 {
                    XCTAssertTrue(sk.anchors.contains(Int(ev.startStep)),
                                  "chord onset \(ev.startStep) off-anchor in bar \(bar) (anchors \(sk.anchors))")
                    chordChecked += 1
                }
            }
        }
        XCTAssertGreaterThan(bassChecked, 8)
        XCTAssertGreaterThan(chordChecked, 8)
    }

    // MARK: - v2: space & hierarchy

    /// Below tension 0.3 with the kit's presence envelope low: a handful of
    /// quiet texture events, no kick/snare, bass silent unless it is the
    /// focus voice. A *fading* kit tail (presence still releasing after a
    /// peak) is legal in a low-tension bar — that blend is the point — so
    /// the drum laws key off presence, not tension.
    func testLowTensionSparseness() {
        let e = Engine(seed: 0xA111)
        e.rewind()
        var quietBars = 0
        var pitchedCounts: [Int] = []
        for bar in 0..<64 {
            let sb = e.evolution.sectionBars
            let cond = e.conductor.state(bar: bar, sectionBars: sb)
            let out = e.generateBar(bar)
            // The engine's own (amount-biased) presence — the law must match
            // what generation actually used.
            let presence = out.snapshot.drumPresence
            guard cond.tension < 0.3 else { continue }
            quietBars += 1
            let drums = out.events.filter { $0.voice == .drums }
            if presence < 0.2 {
                XCTAssertLessThanOrEqual(drums.count, 3, "bar \(bar): \(drums.count) drum events")
                for d in drums {
                    XCTAssertFalse(d.note == DrumTrack.kick.note || d.note == DrumTrack.snare.note,
                                   "kick/snare in quiet bar \(bar)")
                }
            }
            if presence < 0.35 {
                for d in drums {
                    XCTAssertLessThan(d.velocity, 55, "loud drum (vel \(d.velocity)) in quiet bar \(bar)")
                }
            }
            if cond.focus != .bass {
                XCTAssertTrue(out.events.allSatisfy { $0.voice != .bass },
                              "bass playing below 0.3 without focus (bar \(bar))")
            }
            pitchedCounts.append(out.events.filter { $0.voice != .drums && $0.voice != .drone }.count)
        }
        XCTAssertGreaterThan(quietBars, 8, "default arc should have quiet bars")
        let mean = Double(pitchedCounts.reduce(0, +)) / Double(max(1, pitchedCounts.count))
        XCTAssertLessThanOrEqual(mean, 5.0, "quiet bars too busy (mean \(mean))")
        XCTAssertLessThanOrEqual(pitchedCounts.max() ?? 0, 10)
    }

    /// The kit blends: presence is deterministic and slew-limited (no cliffs
    /// except the deliberate drop cut), and the backbone obeys its layering
    /// ladder — loud kicks need presence past the kick rung, loud snares
    /// past the later snare rung, so entries assemble hats → kick → snare
    /// and exits thin in reverse.
    func testDrumPresenceBlends() {
        let e = fastArcEngine(seed: 4711)
        let sb = e.evolution.sectionBars
        var prev: Double? = nil
        for bar in 0..<160 {
            let st = e.conductor.state(bar: bar, sectionBars: sb)
            let out = e.generateBar(bar)
            // The engine's own (amount-biased) presence.
            let p = out.snapshot.drumPresence
            if let q = prev, st.event != .drop, st.event != .vacuum {
                XCTAssertLessThanOrEqual(p - q, 0.5 + 1e-9, "presence rose too fast (bar \(bar))")
                XCTAssertLessThanOrEqual(q - p, 0.22 + 1e-9, "presence fell too fast (bar \(bar))")
            }
            prev = p

            // Ordinary groove bars keep the kick/snare tied to presence. A
            // build is an intentional rush — the drums intensify while the
            // sustained groove is stripped — so its loud roll is exempt.
            if st.event != .build {
                for ev in out.events where ev.voice == .drums && ev.velocity >= 40 {
                    if ev.note == DrumTrack.snare.note {
                        XCTAssertGreaterThan(p, 0.50, "loud snare at presence \(p) (bar \(bar))")
                    }
                    if ev.note == DrumTrack.kick.note {
                        XCTAssertGreaterThan(p, 0.35, "loud kick at presence \(p) (bar \(bar))")
                    }
                }
            }
        }
    }

    /// Once the kit is in, it runs for minutes — it no longer vanishes at every
    /// breakdown. (The earlier bug: the drum generator's own breakdown cap
    /// overrode the conductor's sustain, silencing the kit for whole breakdowns.)
    func testDrumsSustainForMinutes() {
        for seed: UInt64 in [0xE7, 4711] {   // episodic (worst case) + slow-burn
            let e = Engine(seed: seed)
            let secPerBar = 4.0 * 60.0 / e.tempo
            var best = 0, run = 0
            for bar in 0..<700 {
                let d = e.generateBar(bar).events.filter { $0.voice == .drums }.count
                if d >= 2 { run += 1; best = max(best, run) } else { run = 0 }
            }
            let minutes = Double(best) * secPerBar / 60.0
            XCTAssertGreaterThan(minutes, 3.0,
                                 "seed \(seed): kit should run for minutes once in, got \(minutes)")
        }
    }

    /// The textural transition lanes glide (no EDM snaps): the filter opens with
    /// the tension arc, and the reverb-wash swells into the sparse breakdown and
    /// pulls back at the dense peak.
    func testTransitionAutomation() {
        let e = fastArcEngine(seed: 4711)
        let sb = e.evolution.sectionBars
        func mean(_ a: [Int]) -> Double { Double(a.reduce(0, +)) / Double(max(1, a.count)) }
        func firstCC(_ out: BarOutput, _ controller: Int) -> Int? {
            out.controls.first { $0.controller == controller }?.value
        }
        var brightPeak: [Int] = [], brightBreak: [Int] = []
        var washPeak: [Int] = [], washBreak: [Int] = []
        for bar in 0..<240 {
            let st = e.conductor.state(bar: bar, sectionBars: sb)
            let out = e.generateBar(bar)
            let bright = firstCC(out, ControlLanes.brightnessController)
            let wash = firstCC(out, ControlLanes.reverbWashController)
            switch st.section {
            case .peak:
                bright.map { brightPeak.append($0) }; wash.map { washPeak.append($0) }
            case .breakdown:
                bright.map { brightBreak.append($0) }; wash.map { washBreak.append($0) }
            default: break
            }
        }
        XCTAssertFalse(brightPeak.isEmpty); XCTAssertFalse(brightBreak.isEmpty)
        XCTAssertGreaterThan(mean(brightPeak), mean(brightBreak) + 12,
                             "filter opens wider at the energetic peak than in a breakdown")
        XCTAssertFalse(washPeak.isEmpty); XCTAssertFalse(washBreak.isEmpty)
        XCTAssertGreaterThan(mean(washBreak), mean(washPeak) + 12,
                             "reverb washes into the sparse breakdown, not the dense peak")
    }

    /// Focus: deterministic and constant within a section (the point of a
    /// foreground voice is that it holds the floor).
    func testFocusVoice() {
        let c = Conductor(seed: 33)
        var prev: (section: Section, bar: Int, focus: Voice)? = nil
        for bar in 0..<200 {
            let s1 = c.state(bar: bar, sectionBars: 16)
            let s2 = c.state(bar: bar, sectionBars: 16)
            XCTAssertEqual(s1.focus, s2.focus)
            if let p = prev, p.section == s1.section, s1.sectionBar > 0, p.bar == bar - 1 {
                XCTAssertEqual(p.focus, s1.focus, "focus flickered within a section (bar \(bar))")
            }
            prev = (s1.section, bar, s1.focus)
        }
    }

    // MARK: - v3: key journeys

    /// The journey: deterministic, opens at home, modulates only at phrase
    /// starts, moves only to related keys, and never stays away for more
    /// than three regions.
    func testJourneyRegions() {
        let he = HarmonyEngine(key: 9, scale: .minor, seed: 77)
        let flat: (Int) -> Double = { _ in 0.3 }
        var regions: [JourneyRegion] = []
        for bar in 0..<600 {
            let r = he.journeyRegion(atBar: bar, tensionAt: flat)
            XCTAssertEqual(r, he.journeyRegion(atBar: bar, tensionAt: flat))
            if r != regions.last {
                if let p = regions.last { XCTAssertEqual(r.index, p.index + 1) }
                regions.append(r)
            }
        }
        XCTAssertEqual(regions[0].key, 9, "region 0 must be home")
        XCTAssertEqual(regions[0].scale, .minor)
        if regions.count > 1 {
            XCTAssertGreaterThanOrEqual(regions[1].startBar, 48, "home region too short")
        }
        XCTAssertGreaterThan(regions.count, 3, "600 bars should traverse several regions")
        for r in regions.dropFirst() {
            let ctx = he.context(atBar: r.startBar, tension: 0.3, wander: 0.25, tensionAt: flat)
            XCTAssertEqual(ctx.barInPhrase, 0, "region \(r.index) started mid-phrase")
            XCTAssertEqual(ctx.regionIndex, r.index)
        }
        for (i, r) in regions.enumerated().dropFirst() {
            let p = regions[i - 1]
            let related = [(p.key + 3) % 12, (p.key + 9) % 12, (p.key + 5) % 12,
                           (p.key + 7) % 12, p.key, 9]
            XCTAssertTrue(related.contains(r.key),
                          "region \(r.index) key \(r.key) unrelated to \(p.key)")
        }
        var away = 0
        for r in regions {
            if r.key == 9 && r.scale == .minor { away = 0 } else {
                away += 1
                XCTAssertLessThanOrEqual(away, 3, "journey never came home")
            }
        }
    }

    // MARK: - v3: phrase grammar

    /// Sentences, not ramblings: consequent (odd) phrases open by restating
    /// their antecedent's opening cell, and close on the root more often
    /// than antecedents do (which are steered to end open on 3rd/5th).
    func testPhraseGrammar() {
        let e = fastArcEngine(seed: 606)
        var conOpenings = 0, conRestatements = 0
        var antRoot = 0, antTotal = 0, conRoot = 0, conTotal = 0
        for bar in 0..<160 {
            let h = harmony(of: e, bar: bar)
            let t = tension(of: e, bar: bar)
            let out = e.generateBar(bar)
            let motifNotes = out.events.filter { $0.voice == .melody && !$0.glide }
            guard t >= 0.55 else { continue }
            if h.barInPhrase == 0, h.phraseIndex % 2 == 1,
               let entry = e.motifMemory.recallLog.last, entry.bar == bar, entry.cellID != nil {
                conOpenings += 1
                if entry.transform != nil { conRestatements += 1 }
            }
            if h.barInPhrase == h.phraseBars - 1,
               let last = motifNotes.max(by: { $0.startStep < $1.startStep }) {
                let pc = ((last.note % 12) + 12) % 12
                if h.phraseIndex % 2 == 1 {
                    conTotal += 1; if pc == h.chord.rootPC { conRoot += 1 }
                } else {
                    antTotal += 1; if pc == h.chord.rootPC { antRoot += 1 }
                }
            }
        }
        if conOpenings > 2 {
            XCTAssertGreaterThan(Double(conRestatements), Double(conOpenings) * 0.5,
                                 "answers should mostly restate their question (\(conRestatements)/\(conOpenings))")
        }
        if conTotal > 2 && antTotal > 2 {
            XCTAssertGreaterThanOrEqual(Double(conRoot) / Double(conTotal),
                                        Double(antRoot) / Double(antTotal),
                                        "answers (\(conRoot)/\(conTotal)) should close home at least as often as questions (\(antRoot)/\(antTotal))")
        }
    }

    /// Grace notes appear once the arc is up: quarter-step-early short
    /// events exist in the high-tension band. (Transforms also produce
    /// off-grid notes, so absence below the threshold can't be asserted
    /// from output alone.)
    func testOrnaments() {
        let e = fastArcEngine(seed: 909)
        var graceLike = 0
        for bar in 0..<96 {
            let t = tension(of: e, bar: bar)
            guard t >= 0.5 else { _ = e.generateBar(bar); continue }
            let melody = e.generateBar(bar).events.filter { $0.voice == .melody }
            graceLike += melody.filter {
                $0.startStep.truncatingRemainder(dividingBy: 0.5) != 0 && $0.durationSteps <= 0.35
            }.count
        }
        XCTAssertGreaterThan(graceLike, 0, "no ornaments in the high-tension band")
    }

    // MARK: - v3: arrangement events

    /// Ambient arrangement: sections change gradually. The only autonomous
    /// boundary event is the gentle exhale as a peak dissolves into a breakdown —
    /// no EDM build-up, pre-drop vacuum or slammed drop.
    func testSectionEvents() {
        let c = Conductor(seed: 0xE7)
        var exhales = 0
        for bar in 0..<800 {
            let s = c.state(bar: bar, sectionBars: 16)
            XCTAssertEqual(s.event, c.state(bar: bar, sectionBars: 16).event)  // deterministic
            switch s.event {
            case .exhale:
                XCTAssertEqual(s.section, .breakdown)
                XCTAssertLessThan(s.sectionBar, c.exhaleBars())
                exhales += 1
            case .build, .vacuum, .drop:
                XCTFail("autonomous EDM event \(s.event!) at bar \(bar) — should be gone")
            case nil:
                break
            }
        }
        XCTAssertGreaterThan(exhales, 0, "peaks should exhale into breakdowns")

        // The kit fades *through* an exhale (its presence envelope releases over
        // it) as a soft tail — it isn't slammed or cut hard.
        let e = fastArcEngine(seed: 0xD0D0)
        for bar in 0..<160 {
            let cond = e.conductor.state(bar: bar, sectionBars: e.evolution.sectionBars)
            let out = e.generateBar(bar)
            if cond.event == .exhale {
                for d in out.events where d.voice == .drums {
                    XCTAssertLessThan(d.velocity, 110,
                                      "exhale drum tail too loud (vel \(d.velocity), bar \(bar))")
                }
            }
        }
    }

    // MARK: - v3: drum grammar & deja-vu

    /// A reliable trip-hop spine (documented kick / snare / swung hats) for the
    /// spine and role tests. Ghosts and ratchets are silenced so exact-position
    /// checks are not perturbed by decoration.
    func drumParams(recur: Double) -> ParamSet {
        var p = Defaults.params(for: .drums)
        p["genre"] = 0.4    // pin trip-hop
        p["ghost"] = 0
        p["ratchet"] = 0
        p["recur"] = recur
        return p
    }

    /// Genre selection is deterministic; an explicit control pins the family;
    /// the auto default stays sparse & supportive (no jungle on the ambient core).
    func testGenreSelectionDeterministic() {
        for seed in stride(from: UInt64(0), to: 400, by: 37) {
            let a = DrumGenre.resolve(control: 0, dialect: .ambient, seed: seed, legacy: nil)
            let b = DrumGenre.resolve(control: 0, dialect: .ambient, seed: seed, legacy: nil)
            XCTAssertEqual(a, b, "auto genre must be stable for a seed")
        }
        for (control, genre): (Double, DrumGenre) in
            [(0.2, .ambient), (0.4, .tripHop), (0.6, .jungle), (0.8, .idm)] {
            for seed in [UInt64(1), 99, 12345] {
                XCTAssertEqual(DrumGenre.resolve(control: control, dialect: .cinematic,
                                                 seed: seed, legacy: nil), genre)
            }
        }
        var jungle = 0
        for seed in UInt64(0)..<200 where
            DrumGenre.resolve(control: 0, dialect: .ambient, seed: seed, legacy: nil) == .jungle {
            jungle += 1
        }
        XCTAssertEqual(jungle, 0, "the ambient dialect should not auto-select jungle")
    }

    /// Each density lane is eliminated at zero: skins removes the core, hats the
    /// timekeepers, perc the shaker / effects.
    func testLaneZeroEliminates() {
        let seed: UInt64 = 0x1A2B
        let feel = Feel(seed: seed, voice: .drums)
        func fire(_ mutate: (inout ParamSet) -> Void) -> Set<Int> {
            var out: Set<Int> = []
            for bar in 0..<16 {
                var p = Defaults.params(for: .drums)
                p["genre"] = 0.4; p["recur"] = 0; p["ratchet"] = 0
                p["ghost"] = 0; p["kit"] = 0.6
                mutate(&p)
                let evs = DrumGenerator.generate(bar: bar, params: p, subSeed: seed,
                                                 profileSeed: seed, feel: feel, fill: 0,
                                                 tension: 0.85, presence: 0.95,
                                                 nextPresence: 0.95, anchors: [0, 4, 8, 12])
                for e in evs { out.insert(e.note) }
            }
            return out
        }
        let noSkins = fire { $0["punch"] = 0 }
        XCTAssertFalse(noSkins.contains(DrumTrack.kick.note), "punch 0 must remove the kick")
        XCTAssertFalse(noSkins.contains(DrumTrack.snare.note), "punch 0 must remove the snare")
        let noHats = fire { $0["density"] = 0 }
        XCTAssertFalse(noHats.contains(DrumTrack.hat.note), "density 0 must remove the hats")
        XCTAssertFalse(noHats.contains(DrumTrack.hatOpen.note), "density 0 must remove the open hats")
        let noPerc = fire { $0["perc"] = 0 }
        XCTAssertFalse(noPerc.contains(DrumTrack.shaker.note), "perc 0 must remove the shaker")
        XCTAssertFalse(noPerc.contains(DrumTrack.ride.note), "perc 0 must remove the ride")
        let full = fire { $0["punch"] = 0.8; $0["density"] = 0.8; $0["perc"] = 0.8 }
        XCTAssertTrue(full.contains(DrumTrack.kick.note))
        XCTAssertTrue(full.contains(DrumTrack.hat.note))
    }

    /// The layers peel in order with presence — kick before hats before the
    /// snare backbeat — and everything fades toward silence as presence drops.
    func testArrangementPeel() {
        var kickOnset = 2.0, hatOnset = 2.0, snareOnset = 2.0
        for i in 0...40 {
            let p = Double(i) / 40.0
            let L = DrumLayers.compute(presence: p)
            if L.coreGate > 0.05 && kickOnset > 1 { kickOnset = p }
            if L.eighthGate > 0.05 && hatOnset > 1 { hatOnset = p }
            if L.snareGate > 0.05 && snareOnset > 1 { snareOnset = p }
        }
        XCTAssertLessThan(kickOnset, hatOnset, "the kick must enter before the hats")
        XCTAssertLessThan(hatOnset, snareOnset, "hats must enter before the backbeat snare")
        XCTAssertFalse(DrumLayers.compute(presence: 0.15).coreOn, "near-zero presence has no kit")
        XCTAssertTrue(DrumLayers.compute(presence: 0.7).coreOn, "a present kit sounds")
    }

    /// Valley drums are a readable side-stick landmark, not scattered toms.
    func testSparseDrumTextureIsIntentional() {
        let seed: UInt64 = 881
        let feel = Feel(seed: seed, voice: .drums)
        var heard = 0
        for bar in 0..<24 {
            let events = DrumGenerator.generate(bar: bar, params: drumParams(recur: 0),
                                                subSeed: seed, profileSeed: seed,
                                                feel: feel, fill: 0, tension: 0.3,
                                                presence: 0, nextPresence: 0,
                                                anchors: [0, 8])
            XCTAssertLessThanOrEqual(events.count, 1)
            for ev in events {
                heard += 1
                XCTAssertEqual(ev.note, DrumTrack.rim.note)
                XCTAssertTrue(ev.startStep == 6 || ev.startStep == 14)
                XCTAssertLessThan(ev.velocity, 55)
            }
        }
        XCTAssertGreaterThan(heard, 0)
    }

    /// At full presence, every style has a dependable kick/snare spine and
    /// closed hats on the quarter notes. Variation may decorate that spine.
    func testDrumBackboneNeverRandomlyDrops() {
        let feel = Feel(seed: 0xBACC, voice: .drums)
        for (control, genre): (Double, DrumGenre) in
            [(0.4, .tripHop), (0.6, .jungle), (0.8, .idm)] {
            let seed: UInt64 = 0x51 &+ UInt64(control * 10)
            let pattern = DrumPatternLibrary.pattern(genre: genre, seed: seed)
            var p = Defaults.params(for: .drums)
            p["genre"] = control; p["punch"] = 0.85; p["density"] = 0.85
            p["ghost"] = 0; p["ratchet"] = 0; p["recur"] = 0; p["kit"] = 0
            let events = DrumGenerator.generate(bar: 0, params: p, subSeed: seed,
                                                profileSeed: seed, feel: feel, fill: 0,
                                                tension: 0.8, presence: 1, nextPresence: 1,
                                                anchors: [0, 4, 8, 12])
            let kickSteps = Set(events.filter { $0.note == DrumTrack.kick.note }.map { Int($0.startStep) })
            let snareSteps = Set(events.filter { $0.note == DrumTrack.snare.note }.map { Int($0.startStep) })
            let hatSteps = Set(events.filter { $0.note == DrumTrack.hat.note }.map { Int($0.startStep) })
            let coreKick = Set(pattern.core.filter { $0.track == .kick }.map { Int($0.step) })
            let coreSnare = Set(pattern.core.filter { $0.track == .snare }.map { Int($0.step) })
            XCTAssertTrue(coreKick.isSubset(of: kickSteps), "\(genre) dropped a core kick")
            XCTAssertTrue(coreSnare.isSubset(of: snareSteps), "\(genre) dropped a core snare")
            XCTAssertFalse(hatSteps.isEmpty, "\(genre) must hold a hat timekeeper")
            XCTAssertTrue(kickSteps.contains(0), "\(genre) must hit the downbeat")
        }
    }

    /// The `kit` width control is gated: at kit 0 only the core pads (≤ note 46)
    /// ever sound; a wide kit at a peak reaches into the top-row pads (48–51)
    /// and the shaker (44), all still inside the 16-pad rack range.
    func testKitWidthGating() {
        let feel = Feel(seed: 0x5151, voice: .drums)
        func notes(kit: Double) -> Set<Int> {
            var out: Set<Int> = []
            for bar in 0..<24 {
                let p = ParamSet(voice: .drums, defaults: [
                    "genre": 0.4, "punch": 0.7, "perc": 0.6,
                    "density": 0.7, "swing": 0.2, "ghost": 0.4, "ratchet": 0.2,
                    "fills": 0.6, "poly": 0.2, "recur": 0.4, "dynamics": 0.7,
                    "humanize": 0.4, "kit": kit])
                let evs = DrumGenerator.generate(bar: bar, params: p, subSeed: 0xD1,
                                                 profileSeed: 0xD1, feel: feel, fill: 0.5,
                                                 tension: 0.85, presence: 0.95,
                                                 nextPresence: 0.95, anchors: [0, 4, 8, 12],
                                                 accentDownbeat: bar % 8 == 0)
                for e in evs { out.insert(e.note) }
            }
            return out
        }
        // The extended-percussion pads (shaker 44, one-shots 48/50, crash 49,
        // ride 51). Toms (41/43/45/47) are core fills, allowed at any width.
        let extended: Set<Int> = [44, 48, 49, 50, 51]
        let core = notes(kit: 0)
        XCTAssertTrue(core.isDisjoint(with: extended), "kit 0 must not touch the extended pads, got \(core.sorted())")
        XCTAssertTrue(core.allSatisfy { (36...51).contains($0) }, "kit 0 stays in the 16-pad range, got \(core.sorted())")
        let wide = notes(kit: 0.9)
        XCTAssertFalse(wide.intersection(extended).isEmpty,
                       "a wide kit must reach the extended pads, got \(wide.sorted())")
        XCTAssertTrue(wide.allSatisfy { (36...51).contains($0) },
                      "everything stays inside the 16-pad range, got \(wide.sorted())")
    }

    /// A normal groove never scatters toms, and an open hat replaces the
    /// closed hat at the same instant so standard choke groups behave cleanly.
    func testDrumRolesStayCleanBetweenFills() {
        let seed: UInt64 = 0xC10C
        let feel = Feel(seed: seed, voice: .drums)
        var p = drumParams(recur: 0)
        p["perc"] = 0   // isolate: perc lane off, so no fill/friction toms leak in
        for bar in 0..<32 {
            let events = DrumGenerator.generate(bar: bar, params: p,
                                                subSeed: seed, profileSeed: seed,
                                                feel: feel, fill: 0, tension: 0.8,
                                                presence: 1, nextPresence: 1,
                                                anchors: [0, 4, 8, 12])
            XCTAssertFalse(events.contains {
                $0.note == DrumTrack.tomLo.note || $0.note == DrumTrack.tomHi.note
            }, "toms should be reserved for fills")
            let closed = Set(events.filter { $0.note == DrumTrack.hat.note }.map { Int($0.startStep) })
            let open = Set(events.filter { $0.note == DrumTrack.hatOpen.note }.map { Int($0.startStep) })
            XCTAssertTrue(closed.isDisjoint(with: open), "open and closed hat doubled in bar \(bar)")
        }
    }

    /// Grit edits only phrase-scale boundary bars, and does so with authored
    /// gestures (flams, bursts or tom answers) rather than random scattering.
    func testDrumFracturesBendLearnedPatterns() {
        let seed: UInt64 = 0xF12A
        let feel = Feel(seed: seed, voice: .drums)
        var p = drumParams(recur: 1)
        p["perc"] = 0   // isolate fracture gestures from the base perc lane
        var markedEdits = 0
        for bar in 0..<64 {
            let events = DrumGenerator.generate(bar: bar, params: p,
                                                subSeed: seed, profileSeed: seed,
                                                feel: feel, fill: 0, tension: 0.85,
                                                presence: 1, nextPresence: 1,
                                                anchors: [0, 4, 8, 12], friction: 1)
            let hasTom = events.contains {
                $0.note == DrumTrack.perc.note || $0.note == DrumTrack.glitch.note
            }
            let hasEditSubdivision = events.contains {
                $0.startStep.truncatingRemainder(dividingBy: 0.5) != 0
            }
            if hasTom || hasEditSubdivision {
                markedEdits += 1
                XCTAssertTrue([3, 5, 7].contains(bar % 8),
                              "fracture escaped phrase boundary at bar \(bar)")
            }
        }
        XCTAssertGreaterThan(markedEdits, 3, "grit produced no audible phrase edits")
    }

    /// The core is a foundation, not a per-bar re-roll: at constant presence the
    /// kick + snare identity is byte-identical bar to bar. Variation lives in the
    /// layers and the arrangement, never in the backbone.
    func testCoreIdentityStable() {
        let seed: UInt64 = 991
        let feel = Feel(seed: seed, voice: .drums)
        func core(_ bar: Int) -> Set<String> {
            Set(DrumGenerator.generate(bar: bar, params: drumParams(recur: 0),
                                       subSeed: seed, profileSeed: seed, feel: feel,
                                       fill: 0, tension: 0.8, presence: 0.9,
                                       nextPresence: 0.9, anchors: [0, 4, 8, 12])
                .filter { $0.note == DrumTrack.kick.note || $0.note == DrumTrack.snare.note }
                .map { "\($0.note)@\(Int($0.startStep))" })
        }
        let ref = core(0)
        XCTAssertFalse(ref.isEmpty, "the core must sound at full presence")
        for bar in 1..<16 {
            XCTAssertEqual(core(bar), ref, "core identity drifted at bar \(bar)")
        }
    }

    // MARK: - v3: groove signature

    /// The pocket is asymmetric by role: over a long run the snare's mean
    /// timing offset sits measurably behind the kick's, and the drone stays
    /// exactly on the grid.
    func testGrooveSignature() {
        let e = fastArcEngine(seed: 2323)
        var kick: [Double] = [], snare: [Double] = []
        for bar in 0..<160 {
            for ev in e.generateBar(bar).events {
                if ev.voice == .drums {
                    if ev.note == DrumTrack.kick.note { kick.append(ev.timingOffset) }
                    if ev.note == DrumTrack.snare.note { snare.append(ev.timingOffset) }
                }
                if ev.voice == .drone {
                    XCTAssertEqual(ev.timingOffset, 0, "the drone must stay on the grid")
                }
            }
        }
        func mean(_ a: [Double]) -> Double { a.reduce(0, +) / Double(max(1, a.count)) }
        XCTAssertGreaterThan(kick.count, 10)
        XCTAssertGreaterThan(snare.count, 10)
        XCTAssertGreaterThan(mean(snare), mean(kick) + 0.005,
                             "snare (\(mean(snare))) should lay back behind the kick (\(mean(kick)))")
    }

    // MARK: - v3: movements

    /// A new journey region freshens the material vocabulary — different
    /// loop bank and drum profiles per movement, identical within one, and
    /// locked voices keep movement 0's material.
    func testMovementMaterialRefresh() {
        let e = Engine(seed: 4141)
        let s0 = e.materialSeed(for: .melody, movement: 0)
        let s1 = e.materialSeed(for: .melody, movement: 1)
        let s2 = e.materialSeed(for: .melody, movement: 2)
        XCTAssertNotEqual(s0, s1)
        XCTAssertNotEqual(s1, s2)
        XCTAssertEqual(s1, e.materialSeed(for: .melody, movement: 1), "salt must be stable")
        let bank0 = LoopPattern.bank(subSeed: s0)
        let bank1 = LoopPattern.bank(subSeed: s1)
        XCTAssertFalse(zip(bank0, bank1).allSatisfy {
            $0.periodSteps == $1.periodSteps && $0.offsetSteps == $1.offsetSteps
                && $0.durSteps == $1.durSteps
        }, "movement 1 should bring a different loop vocabulary")
        e.evolution.locked[.melody] = true
        XCTAssertEqual(e.materialSeed(for: .melody, movement: 3), s0,
                       "locked voices keep movement 0's material")
    }

    /// fade() keeps the freshest half of the motif cells.
    func testMotifFade() {
        let m = MotifMemory()
        for _ in 0..<6 {
            _ = m.store(MotifCell(notes: [.init(step: 0, degree: 0, dur: 1, vel: 0.5)], id: 0))
        }
        let newestID = m.cells.last!.id
        m.fade()
        XCTAssertEqual(m.cells.count, 3)
        XCTAssertEqual(m.cells.last!.id, newestID, "the freshest cell survives the fade")
    }

    // MARK: - v4: persistent compositional identity

    func testCompositionVersionDefaultsAndReseeding() {
        let current = Engine(seed: 1)
        XCTAssertEqual(current.compositionVersion, .persistentThemes)
        XCTAssertNotNil(current.themeBlueprint)

        let legacy = Engine(seed: 1, compositionVersion: .legacy)
        XCTAssertEqual(legacy.compositionVersion, .legacy)
        XCTAssertNil(legacy.themeBlueprint)
        legacy.mutate()
        XCTAssertEqual(legacy.compositionVersion, .legacy,
                       "mutation must preserve the active composition model")
        legacy.reseed(2)
        XCTAssertEqual(legacy.compositionVersion, .persistentThemes,
                       "choosing a new seed starts the current model")
        legacy.reseed(3, compositionVersion: .legacy)
        XCTAssertEqual(legacy.compositionVersion, .legacy)
    }

    func testPersistentThemeIdentityAndBlueprintLaw() {
        var lengths: Set<Int> = []
        var intervals: Set<ThemeIntervalProfile> = []
        var rhythms: Set<ThemeRhythmProfile> = []
        var echoes: Set<ThemeEchoRole> = []

        for seed in UInt64(0)..<96 {
            let engine = Engine(seed: seed)
            guard let identity = engine.pieceIdentity,
                  let blueprint = engine.themeBlueprint else {
                return XCTFail("persistent engine missing its identity")
            }
            lengths.insert(identity.themeBars)
            intervals.insert(identity.intervalProfile)
            rhythms.insert(identity.rhythmProfile)
            echoes.insert(identity.echoRole)
            XCTAssertEqual(blueprint.cells.count, identity.themeBars)

            for index in 1..<blueprint.cells.count {
                XCTAssertEqual(blueprint.cells[index].notes.first?.degree,
                               blueprint.cells[index - 1].notes.last?.degree,
                               "seed \(seed): theme restarted at bar \(index)")
            }
            let climax = blueprint.cells.enumerated().flatMap { bar, cell in
                cell.notes.map { (bar, $0.degree) }
            }.filter { $0.1 == 6 }
            XCTAssertEqual(climax.count, 1, "seed \(seed): theme needs one climax")
            if let peakBar = climax.first?.0 {
                XCTAssertGreaterThan(peakBar, 0)
                XCTAssertLessThan(peakBar, identity.themeBars - 1)
            }
            XCTAssertEqual(blueprint.cells.last?.notes.suffix(2).map(\.degree), [1, 0],
                           "seed \(seed): closing gesture changed")
            XCTAssertTrue(blueprint.cells.flatMap(\.notes).allSatisfy {
                $0.step >= 0 && $0.step < Double(stepsPerBar) && $0.dur > 0
            })
        }
        XCTAssertEqual(lengths, [4, 8])
        XCTAssertEqual(intervals, Set(ThemeIntervalProfile.allCases))
        XCTAssertEqual(rhythms, Set(ThemeRhythmProfile.allCases))
        XCTAssertEqual(echoes, Set(ThemeEchoRole.allCases))
    }

    func testPersistentThemeDeterminismRewindAndMutation() {
        func configured() -> Engine {
            let engine = Engine(seed: 0x741E)
            engine.evolution.sectionLength = 0
            engine.evolution.wander = 0.83
            engine.evolution.grit = 0.61
            engine.params[.melody]?["density"] = 0.77
            engine.params[.melody]?["rest"] = 0.21
            return engine
        }
        let a = configured()
        let b = configured()
        let first = streamDigest(a, bars: 96, controls: true)
        XCTAssertEqual(first, streamDigest(b, bars: 96, controls: true))
        a.rewind()
        XCTAssertEqual(first, streamDigest(a, bars: 96, controls: true),
                       "rewind must replay notes and controller lanes exactly")

        let before = a.themeBlueprint?.cells.map { $0.notes.map(\.degree) }
        a.mutate()
        XCTAssertEqual(a.compositionVersion, .persistentThemes)
        XCTAssertEqual(a.themeBlueprint?.cells.map { $0.notes.map(\.degree) }, before,
                       "mutation should develop a piece without replacing its blueprint")

        let locked = configured()
        locked.evolution.locked[.melody] = true
        let melodySeed = locked.subSeeds[.melody]
        locked.mutate()
        XCTAssertEqual(locked.subSeeds[.melody], melodySeed,
                       "melody locking must retain its theme-realization stream")
    }

    func testThemeFormReprisesAfterJourneyChanges() {
        let engine = fastArcEngine(seed: 0xA11CE)
        engine.evolution.push = 1
        engine.params[.melody]?["density"] = 1
        engine.params[.melody]?["rest"] = 0
        guard let blueprint = engine.themeBlueprint else { return XCTFail("missing theme") }

        var sawRoles: Set<PhrasePairRole> = []
        var repriseAcrossJourney = false
        for bar in 0..<512 {
            let h = harmony(of: engine, bar: bar)
            let plan = blueprint.plan(for: h)
            if let plan { sawRoles.insert(plan.role) }
            let output = engine.generateBar(bar)
            guard h.regionIndex > 0, let plan, plan.role == .reprise,
                  let entry = engine.motifMemory.recallLog.last,
                  entry.bar == bar, entry.transform == .transpose else { continue }
            XCTAssertEqual(entry.cellID, 100_000 + plan.sourceIndex)
            let realized = output.events.filter { $0.voice == .melody && !$0.glide }
            XCTAssertTrue(realized.allSatisfy {
                h.latticeMask[(($0.note % 12) + 12) % 12]
            }, "re-rooted reprise escaped the current harmony")
            repriseAcrossJourney = true
            break
        }
        XCTAssertEqual(sawRoles, [.statement, .development, .departure, .reprise])
        XCTAssertTrue(repriseAcrossJourney,
                      "no stable-ID reprise survived into a later journey region")
    }

    func testThemeControlsAndCandidateOnlyEchoes() {
        let engine = Engine(seed: 0xEC40)
        guard let blueprint = engine.themeBlueprint,
              let source = blueprint.cells.first,
              let closing = blueprint.cells.last else {
            return XCTFail("missing theme")
        }
        let thin = MelodyGenerator.shapedThemeCell(source, density: 0, contour: 0.5,
                                                   subSeed: 9, bar: 0)
        let full = MelodyGenerator.shapedThemeCell(source, density: 1, contour: 0.5,
                                                   subSeed: 9, bar: 0)
        let falling = MelodyGenerator.shapedThemeCell(source, density: 1, contour: 0,
                                                      subSeed: 9, bar: 0)
        let rising = MelodyGenerator.shapedThemeCell(source, density: 1, contour: 1,
                                                     subSeed: 9, bar: 0)
        XCTAssertLessThanOrEqual(thin.notes.count, full.notes.count)
        XCTAssertNotEqual(falling.notes.map(\.degree), rising.notes.map(\.degree))
        let shapedClose = MelodyGenerator.shapedThemeCell(
            closing, density: 1, contour: 1, subSeed: 9,
            bar: blueprint.cells.count - 1, preserveClosingGesture: true)
        XCTAssertEqual(shapedClose.notes.suffix(2).map(\.degree), [1, 0])

        let h = harmony(of: engine, bar: 0)
        let quoted = MotifCell(notes: [
            .init(step: 4, degree: 0, dur: 1, vel: 0.5),
            .init(step: 12, degree: 1, dur: 1, vel: 0.5),
        ], id: 88)
        func context(echo: Voice) -> EnsembleContext {
            EnsembleContext(anchors: [0, 4, 8, 12], gaps: [1..<4, 5..<8, 9..<12],
                            focus: echo, speaking: true, prevMelodyGesture: false,
                            motifCell: nil, chordVoicing: [48, 55, 60],
                            themeCell: quoted, themeEchoVoice: echo)
        }
        var bassParams = Defaults.params(for: .bass)
        bassParams["density"] = 1
        let bass = BassGenerator.generate(bar: 0, params: bassParams, harmony: h,
                                          subSeed: 0xB455, feel: Feel(seed: 1, voice: .bass),
                                          tension: 0.8, isFocus: true,
                                          ensemble: context(echo: .bass))
        XCTAssertFalse(bass.isEmpty)
        XCTAssertTrue(bass.allSatisfy { [0.0, 4.0, 12.0].contains($0.startStep) },
                      "bass echo invented an onset outside its anchors")

        var pulseParams = Defaults.params(for: .pulse)
        pulseParams["density"] = 1
        pulseParams["division"] = 0.5
        pulseParams["ratchet"] = 0
        let pulse = PulseGenerator.generate(bar: 0, params: pulseParams, harmony: h,
                                            subSeed: 0x5055, feel: Feel(seed: 1, voice: .pulse),
                                            tension: 0.8, ensemble: context(echo: .pulse),
                                            event: nil, friction: 0)
        XCTAssertFalse(pulse.isEmpty)
        XCTAssertTrue(pulse.allSatisfy {
            $0.startStep.rounded() == $0.startStep && Int($0.startStep).isMultiple(of: 2)
        }, "pulse echo invented an onset outside its existing grid")
    }

    // MARK: - v2.1: consonance

    /// What sustains together is consonant together: across all pitched
    /// voices, no two notes a semitone apart may overlap for more than one
    /// step. (The deliberate high-tension "dark color" pool tone is melodic
    /// spice, not a sustained rub — it is covered by the same bound.)
    func testNoSustainedSemitones() {
        let e = Engine(seed: 0xC0A1)
        e.rewind()
        struct Sounding { let note: Int; let start: Double; let end: Double; let voice: Voice }
        var active: [Sounding] = []
        for bar in 0..<64 {
            let barStart = Double(bar * stepsPerBar)
            let events = e.generateBar(bar).events.filter { $0.voice != .drums }
            for ev in events {
                let s = barStart + ev.startStep
                let new = Sounding(note: ev.note, start: s, end: s + ev.durationSteps, voice: ev.voice)
                for old in active where abs(old.note - new.note) == 1 {
                    let overlap = min(old.end, new.end) - max(old.start, new.start)
                    XCTAssertLessThanOrEqual(overlap, 1.0,
                        "sustained semitone: \(old.voice) \(old.note) vs \(new.voice) \(new.note) overlap \(overlap) steps at bar \(bar)")
                }
                active.append(new)
            }
            active.removeAll { $0.end <= barStart }
        }
    }

    /// The bass never sustains a semitone against anything, in *every* seeded
    /// home key. A high-register drone can fill the low band, and long roots
    /// cross bar lines, so the engine's bass consonance pass — which sees the
    /// whole realized ensemble plus the previous bar's tails — must lift the
    /// bass clear. (Chord-internal voice-leading suspensions are a separate
    /// concern and not asserted here.)
    func testBassNeverSustainsSemitoneAcrossKeys() {
        struct Sounding { let note: Int; let start: Double; let end: Double; let voice: Voice }
        for seed in stride(from: UInt64(1), through: 40, by: 1) {
            let e = Engine(seed: seed)
            e.rewind()
            var active: [Sounding] = []
            for bar in 0..<72 {
                let barStart = Double(bar * stepsPerBar)
                let events = e.generateBar(bar).events.filter { $0.voice != .drums }
                for ev in events {
                    let s = barStart + ev.startStep
                    let new = Sounding(note: ev.note, start: s, end: s + ev.durationSteps, voice: ev.voice)
                    for old in active where abs(old.note - new.note) == 1
                        && (old.voice == .bass || new.voice == .bass) {
                        let overlap = min(old.end, new.end) - max(old.start, new.start)
                        XCTAssertLessThanOrEqual(overlap, 1.0,
                            "seed \(seed): bass semitone \(old.voice) \(old.note) vs \(new.voice) \(new.note) overlap \(overlap) at bar \(bar)")
                    }
                    active.append(new)
                }
                active.removeAll { $0.end <= barStart }
            }
        }
    }

    /// A new seed is a new piece with a new home. Over many seeds the tonic
    /// spreads across pitch classes, and the scale stays weighted toward loom's
    /// dark-minor identity rather than defaulting to bright majors.
    func testSeededHomeVariety() {
        var keys: Set<Int> = []
        var minorFamily = 0
        let n = 200
        for seed in 0..<UInt64(n) {
            let home = HarmonyEngine.seededHome(seed: seed)
            XCTAssertTrue((0..<12).contains(home.key))
            keys.insert(home.key)
            if [.minor, .dorian, .phrygian].contains(home.scale) { minorFamily += 1 }
        }
        XCTAssertGreaterThanOrEqual(keys.count, 8, "home key barely varies (\(keys.count) of 12)")
        XCTAssertGreaterThan(Double(minorFamily) / Double(n), 0.55,
                             "dark-minor identity should dominate (\(minorFamily)/\(n))")
    }

    /// The melody's phrase climax crests inside the phrase, not at its edges,
    /// and reaches higher at higher tension — the mechanism behind a composed
    /// long line rather than a per-bar random walk.
    func testMelodyPhraseClimax() {
        for phraseBars in [4, 8, 16] {
            let (peak, height) = MelodyGenerator.phraseClimax(
                phraseBars: phraseBars, subSeed: 0xABCD, phraseIndex: 3, tension: 0.8)
            XCTAssertGreaterThan(peak, 0, "peak at the phrase start")
            XCTAssertLessThan(peak, phraseBars - 1, "peak at the phrase end")
            XCTAssertGreaterThan(height, 0)
            let atPeak = MelodyGenerator.climaxShape(barInPhrase: peak, peakBar: peak, phraseBars: phraseBars).height
            let atStart = MelodyGenerator.climaxShape(barInPhrase: 0, peakBar: peak, phraseBars: phraseBars).height
            let atEnd = MelodyGenerator.climaxShape(barInPhrase: phraseBars - 1, peakBar: peak, phraseBars: phraseBars).height
            XCTAssertEqual(atPeak, 1.0, accuracy: 1e-9, "crest reaches full height")
            XCTAssertLessThan(atStart, atPeak, "the line lifts into the crest")
            XCTAssertLessThan(atEnd, atPeak, "the line settles after the crest")
        }
        // Height scales with tension: a peak phrase reaches higher than a calm one.
        let calm = MelodyGenerator.phraseClimax(phraseBars: 8, subSeed: 1, phraseIndex: 0, tension: 0.2).height
        let peaked = MelodyGenerator.phraseClimax(phraseBars: 8, subSeed: 1, phraseIndex: 0, tension: 0.9).height
        XCTAssertGreaterThan(peaked, calm)
    }

    /// The loop layer lives above the bed and clears its own tails: loop
    /// events sit at octave 4+ and never sustain a 2nd against another
    /// ringing loop tail.
    func testLoopRegisterSeparation() {
        let e = Engine(seed: 0x100C)
        e.rewind()
        var loopNotes = 0
        for bar in 0..<48 {
            let t = tension(of: e, bar: bar)
            for ev in e.generateBar(bar).events where ev.voice == .melody && ev.glide && t < 0.35 {
                XCTAssertGreaterThanOrEqual(ev.note, 60, "loop note \(ev.note) below octave 4")
                loopNotes += 1
            }
        }
        XCTAssertGreaterThan(loopNotes, 5)
    }

    /// Bass long roots keep clear of the drone: never a sustained low 2nd
    /// against the span root or its fifth.
    func testBassDroneClearance() {
        let e = Engine(seed: 0xBA55)
        e.rewind()
        let sectionBars = e.evolution.sectionBars
        for bar in 0..<64 {
            let t = tension(of: e, bar: bar)
            guard t >= 0.30, t < 0.45 else { continue }
            let span = e.harmonyEngine.droneSpan(atBar: bar, wander: e.evolution.wander,
                                                 tensionAt: { e.conductor.state(bar: $0, sectionBars: sectionBars).tension })
            for ev in e.generateBar(bar).events where ev.voice == .bass {
                for dronePC in [span.rootPC, (span.rootPC + 7) % 12] {
                    let pc = ((ev.note % 12) + 12) % 12
                    let d = min((pc - dronePC + 12) % 12, (dronePC - pc + 12) % 12)
                    if d == 1 || d == 2 {
                        XCTAssertGreaterThanOrEqual(ev.note, 48,
                            "bass \(ev.note) rubs the drone (pc \(dronePC)) in the low register at bar \(bar)")
                    }
                }
            }
        }
    }

    // MARK: - v2: dynamics

    /// Velocity is shaped, not random: metric accents separate strong from
    /// weak melody positions, the ambient loops breathe over time, and the
    /// kit at a peak sits far above the valley texture layer.
    func testVelocityShaping() {
        let e = fastArcEngine(seed: 4242)
        var strong: [Double] = [], weak: [Double] = []
        var loopVels: [Int] = []
        var kitVels: [Double] = [], textureVels: [Double] = []
        for bar in 0..<128 {
            let t = tension(of: e, bar: bar)
            for ev in e.generateBar(bar).events {
                switch ev.voice {
                case .melody:
                    if ev.glide, t < 0.35 { loopVels.append(ev.velocity) }
                    if !ev.glide, t >= 0.55 {
                        let s = ev.startStep.truncatingRemainder(dividingBy: 16)
                        if s == 0 || s == 8 {
                            strong.append(Double(ev.velocity))
                        } else if s.truncatingRemainder(dividingBy: 1) == 0, Int(s) % 2 == 1 {
                            weak.append(Double(ev.velocity))
                        }
                    }
                case .drums:
                    // The shaker is an intentionally-quiet wide-kit texture, not
                    // part of the backbone dynamic being measured here.
                    if t >= 0.7 && ev.note != DrumTrack.shaker.note { kitVels.append(Double(ev.velocity)) }
                    else if t < 0.3 { textureVels.append(Double(ev.velocity)) }
                default: break
                }
            }
        }
        func mean(_ a: [Double]) -> Double { a.reduce(0, +) / Double(max(1, a.count)) }
        XCTAssertGreaterThan(strong.count, 2)
        XCTAssertGreaterThan(weak.count, 2)
        XCTAssertGreaterThan(mean(strong), mean(weak) + 2,
                             "metric accents should separate strong (\(mean(strong))) from weak (\(mean(weak))) melody steps")
        XCTAssertGreaterThan(loopVels.count, 5)
        XCTAssertGreaterThan(loopVels.max()! - loopVels.min()!, 5,
                             "loop layer should breathe, not sit at one velocity")
        XCTAssertFalse(kitVels.isEmpty)
        XCTAssertFalse(textureVels.isEmpty)
        // Peak clearly above valley. The margin is gentle now — the kit no
        // longer slams an EDM crash/accent at peaks, so the separation is real
        // but softer, as ambient dynamics should be.
        XCTAssertGreaterThan(mean(kitVels), mean(textureVels) + 7,
                             "peak kit (\(mean(kitVels))) should sit above valley texture (\(mean(textureVels)))")
    }

    // MARK: - v2: chord swells & ties

    /// Common tones tie through chord changes: a note still sounding from
    /// the previous chord is never re-struck mid-phrase, and the earlier
    /// emission's duration carries it past the change.
    func testChordTiesAcrossChanges() {
        let e = Engine(seed: 0xC0DE)
        e.evolution.locked[.chords] = true // freeze voicing/spread so the
                                           // recomputed chain is exact
        e.rewind()
        struct Sounding { let note: Int; let endStep: Double }
        var held: [Sounding] = []
        var tiesSeen = 0
        for bar in 0..<96 {
            let h = harmony(of: e, bar: bar)
            let t = tension(of: e, bar: bar)
            let out = e.generateBar(bar)
            let chords = out.events.filter { $0.voice == .chords }
            let barStart = Double(bar * stepsPerBar)

            if t < 0.55, h.isChordChangeBar, h.barInPhrase != 0 {
                let sounding = held.filter { $0.endStep > barStart + 1 }.map(\.note)
                for ev in chords where ev.startStep == 0 {
                    XCTAssertFalse(sounding.contains(ev.note),
                                   "bar \(bar): note \(ev.note) re-struck while tied")
                }
                // Every common tone between the voicings must already be
                // covered by an earlier emission reaching past the change.
                if !sounding.isEmpty { tiesSeen += 1 }
            }
            for ev in chords {
                held.append(Sounding(note: ev.note,
                                     endStep: barStart + ev.startStep + ev.durationSteps))
            }
            held.removeAll { $0.endStep <= barStart }
        }
        XCTAssertGreaterThanOrEqual(tiesSeen, 2,
                                    "suspended swell mode never held a common tone")
    }

    /// Swell mode is sparse: at low tension, chord onsets happen at most
    /// once per two bars on average.
    func testChordSwellSparse() {
        let e = Engine(seed: 0x5E11)
        e.rewind()
        var lowBars = 0, onsetBars = 0
        for bar in 0..<64 {
            let t = tension(of: e, bar: bar)
            let out = e.generateBar(bar)
            guard t < 0.4 else { continue }
            lowBars += 1
            if out.events.contains(where: { $0.voice == .chords }) { onsetBars += 1 }
        }
        XCTAssertGreaterThan(lowBars, 8)
        XCTAssertLessThanOrEqual(Double(onsetBars), Double(lowBars) * 0.5 + 1,
                                 "chord swells too frequent: \(onsetBars)/\(lowBars) bars")
    }

    // MARK: - performance / interest / expression

    func testRequestedDisruption() {
        let e = Engine(seed: 0x5150)
        e.interest.request(.silence)
        _ = e.generateBar(0) // observation schedules the request
        let out = e.generateBar(1)
        XCTAssertEqual(out.snapshot.disruptionLabel, Disruption.silence.rawValue)
        XCTAssertTrue(out.events.allSatisfy { $0.voice == .drone })
        XCTAssertTrue(out.snapshot.causalLabel.contains("silence"))
    }

    func testHarmonicBiteResolves() {
        let e = fastArcEngine(seed: 0xB17E)
        var bite: (bar: Int, output: BarOutput)?
        for bar in 0..<96 {
            let next = e.conductor.state(bar: bar + 1, sectionBars: e.evolution.sectionBars)
            if bite == nil, next.tension >= 0.55, next.event == nil {
                e.interest.request(.harmonicBite)
            }
            let output = e.generateBar(bar)
            if output.snapshot.disruptionLabel == Disruption.harmonicBite.rawValue {
                bite = (bar, output); break
            }
        }
        guard let bite else { return XCTFail("no harmonic bite fired") }
        let h = harmony(of: e, bar: bite.bar)
        let chromatic = bite.output.events.filter { event in
            event.voice == .melody && !h.latticeMask[((event.note % 12) + 12) % 12]
        }
        XCTAssertFalse(chromatic.isEmpty, "bite should contain a chromatic neighbor")
        for note in chromatic {
            XCTAssertLessThanOrEqual(note.durationSteps, 0.5)
            XCTAssertTrue(bite.output.events.contains {
                $0.voice == .melody && abs($0.note - note.note) == 1
                    && abs($0.startStep - note.startStep - 0.5) < 0.001
            }, "chromatic neighbor must resolve by semitone")
        }
    }

    func testPushAndPerformanceGates() {
        let e = Engine(seed: 0x5055)
        e.evolution.push = 0
        let sparse = e.effectiveParams(voice: .melody, bar: 8, tension: 0.6)["density"]
        e.evolution.push = 1
        let full = e.effectiveParams(voice: .melody, bar: 8, tension: 0.6)["density"]
        XCTAssertGreaterThan(full, sparse)

        e.soloed = .drums
        let solo = e.generateBar(0)
        XCTAssertTrue(solo.events.allSatisfy { $0.voice == .drums })
        e.muted[.drums] = true
        XCTAssertTrue(e.generateBar(1).events.isEmpty)
    }

    func testExpressionLanes() {
        let e = Engine(seed: 0xCC11)
        let controls = e.generateBar(0).controls
        XCTAssertTrue(controls.contains { $0.controller == ControlLanes.expressionController })
        XCTAssertTrue(controls.contains { $0.controller == ControlLanes.brightnessController })
        XCTAssertTrue(controls.allSatisfy { (0...127).contains($0.value) })
    }

    func testHarmonicDialectIsCoherent() {
        let e = Engine(seed: 0xD1A1EC7)
        let dialect = e.harmonyEngine.dialect
        for bar in stride(from: 0, to: 160, by: 4) {
            let h = harmony(of: e, bar: bar)
            let phrase = ProgressionBank.phrases.first { $0.name == h.phraseName }
            XCTAssertNotNil(phrase)
            if let phrase {
                XCTAssertTrue(ProgressionBank.supports(phrase, dialect: dialect),
                              "\(phrase.name) escaped \(dialect.rawValue) dialect")
            }
        }
    }

    /// Random startup seeds avoid the lounge-specific dialect, and ambient
    /// low-energy chords remove the major/minor third.
    func testDefaultHarmonyStaysAmbiguous() {
        var ambient: HarmonyEngine?
        for seed in UInt64(0)..<128 {
            let harmony = HarmonyEngine(key: 9, scale: .minor, seed: seed)
            XCTAssertNotEqual(harmony.dialect, .soul)
            if harmony.dialect == .ambient { ambient = harmony }
        }
        let h = ambient!
        let context = h.context(atBar: 0, tension: 0.1, wander: 0.4,
                                tensionAt: { _ in 0.1 })
        let intervals = Set(context.chord.pitchClasses.map {
            ($0 - context.chord.rootPC + 12) % 12
        })
        XCTAssertFalse(intervals.contains(3) || intervals.contains(4),
                       "ambient default declared a cheerful/sad triad")
        XCTAssertTrue(context.chord.label.hasSuffix("sus2"))
    }

    /// Chromaticism is measured and gated: none at grit-zero, present at higher
    /// grit, and every secondary dominant is lawful — its tones sit in that
    /// bar's lattice (so voices may sound the leading tone that bar) and it
    /// resolves to a diatonic chord.
    func testGatedChromaticism() {
        let flat: (Int) -> Double = { _ in 0.5 }
        // grit-zero stays strictly diatonic.
        let d = HarmonyEngine(key: 9, scale: .minor, seed: 0xC7)
        for bar in 0..<240 {
            let c = d.context(atBar: bar, tension: 0.7, wander: 0.3, tensionAt: flat, chromaticism: 0)
            XCTAssertFalse(c.chord.label.contains("V7/"),
                           "grit-zero produced a secondary dominant at bar \(bar)")
        }
        // grit-on: secondary dominants appear and are lawful.
        var found = 0
        for seed in UInt64(0)..<40 {
            let h = HarmonyEngine(key: 9, scale: .minor, seed: seed)
            for bar in 0..<64 {
                let c = h.context(atBar: bar, tension: 0.75, wander: 0.3,
                                  tensionAt: flat, chromaticism: 0.85)
                guard c.chord.label.contains("V7/") else { continue }
                found += 1
                XCTAssertTrue(c.isChordChangeBar || c.barInChord == 0
                              || c.chord.pitchClasses.allSatisfy { c.latticeMask[$0] },
                              "applied dominant must be a chord change and lattice-lawful")
                for pc in c.chord.pitchClasses {
                    XCTAssertTrue(c.latticeMask[pc], "applied-dominant tone \(pc) off-lattice at bar \(bar)")
                }
                // Its four tones form a dominant 7th (0,4,7,10 from the root).
                let root = c.chord.rootPC
                let ivals = Set(c.chord.pitchClasses.map { ($0 - root + 12) % 12 })
                XCTAssertEqual(ivals, [0, 4, 7, 10], "V7/x is not a dominant 7th")
            }
        }
        XCTAssertGreaterThan(found, 0, "grit produced no secondary dominants across 40 seeds")
    }

    /// The whole engine stays deterministic with chromaticism (grit) engaged,
    /// and secondary dominants never break the change-bar invariant: a chord
    /// label still changes only on a chord-change bar.
    func testDeterminismWithGrit() {
        func run() -> [Int] {
            let e = Engine(seed: 0x5EED); e.evolution.grit = 0.8; e.rewind()
            return (0..<48).flatMap { e.generateBar($0).events.map(\.note) }
        }
        XCTAssertEqual(run(), run())

        for seed in UInt64(1)...12 {
            let e = Engine(seed: seed); e.evolution.grit = 0.85; e.rewind()
            var prev: String?
            for bar in 0..<96 {
                let snap = e.generateBar(bar).snapshot
                if let p = prev, p != snap.chordLabel {
                    XCTAssertTrue(snap.isChordChangeBar,
                                  "seed \(seed): chord changed to \(snap.chordLabel) off a change bar (\(bar))")
                }
                prev = snap.chordLabel
            }
        }
    }

    func testTwoBarThemeArchive() {
        let memory = MotifMemory()
        let a = MotifCell(notes: [.init(step: 0, degree: 0, dur: 2, vel: 0.5)], id: 41)
        let b = MotifCell(notes: [.init(step: 4, degree: 2, dur: 1, vel: 0.6)], id: 42)
        memory.noteThemeCell(phraseIndex: 0, barInPhrase: 0, cell: a)
        memory.noteThemeCell(phraseIndex: 0, barInPhrase: 1, cell: b)
        XCTAssertEqual(memory.themeCell(forPhrase: 0, barInPhrase: 0)?.id, 41)
        XCTAssertEqual(memory.themeCell(forPhrase: 0, barInPhrase: 1)?.id, 42)
    }

    func testGuardedFormProfilesAndRollingPreview() {
        var examples: [FormProfile: UInt64] = [:]
        for seed in UInt64(0)..<2_000 where examples.count < FormProfile.allCases.count {
            let conductor = Conductor(seed: seed)
            examples[conductor.profile] = examples[conductor.profile] ?? seed
        }
        XCTAssertEqual(examples.count, FormProfile.allCases.count)

        for profile in FormProfile.allCases {
            guard let seed = examples[profile] else { continue }
            let conductor = Conductor(seed: seed)
            XCTAssertEqual(conductor.profile, profile)
            let sectionBars = 24
            var previous = conductor.state(bar: 0, sectionBars: sectionBars)
            for bar in 0..<480 {
                let state = conductor.state(bar: bar, sectionBars: sectionBars)
                XCTAssertGreaterThanOrEqual(state.sectionLength, 4)
                XCTAssertEqual(state.sectionLength % 4, 0)
                if state.sectionBar == 0, bar > 0 {
                    switch previous.section {
                    case .intro:
                        XCTAssertEqual(state.section, .develop)
                    case .develop:
                        XCTAssertTrue([Section.develop, .peak, .breakdown].contains(state.section))
                    case .peak:
                        if profile == .doublePeak {
                            XCTAssertTrue([Section.develop, .breakdown].contains(state.section))
                        } else {
                            XCTAssertEqual(state.section, .breakdown)
                        }
                    case .breakdown:
                        XCTAssertTrue([Section.intro, .develop].contains(state.section))
                    }
                }
                previous = state
            }

            let cues = [ArrangementCue(startBar: 8, kind: .buildDrop)]
            let preview = conductor.preview(startBar: 4, count: 32,
                                            sectionBars: sectionBars, cues: cues)
            XCTAssertEqual(preview.count, 32)
            XCTAssertEqual(preview.map(\.bar), Array(4..<36))
            XCTAssertEqual(preview[4].cue, .buildDrop)
            XCTAssertEqual(preview[4].event, .build)
            XCTAssertEqual(preview[6].event, .vacuum)
            XCTAssertEqual(preview[7].event, .drop)
            XCTAssertEqual(preview, conductor.preview(startBar: 4, count: 32,
                                                       sectionBars: sectionBars, cues: cues),
                           "preview must be deterministic")
        }
    }

    func testAuditedParameterSchemaAndDiscreteModulation() {
        for voice in Voice.allCases {
            let defaults = Defaults.params(for: voice)
            XCTAssertEqual(Set(defaults.names), Set(Defaults.order(for: voice)))
        }
        XCTAssertEqual(Set(Defaults.params(for: .chords).names),
                       Set(["amount", "register", "spread", "humanize"]))
        XCTAssertFalse(Defaults.params(for: .melody).names.contains("octave"))
        XCTAssertFalse(Defaults.params(for: .melody).names.contains("vary"))

        let discrete: Set<ParamID> = [
            ParamID(.drone, "fifth"), ParamID(.drone, "width"),
            ParamID(.drums, "ratchet"), ParamID(.drums, "fills"), ParamID(.drums, "poly"),
            ParamID(.drums, "recur"), ParamID(.drums, "dynamics"), ParamID(.drums, "humanize"),
            ParamID(.bass, "octave"), ParamID(.bass, "follow"), ParamID(.bass, "approach"),
            ParamID(.bass, "accent"), ParamID(.bass, "glide"), ParamID(.bass, "recur"),
            ParamID(.chords, "spread"), ParamID(.chords, "humanize"),
            ParamID(.pulse, "division"), ParamID(.pulse, "octave"), ParamID(.pulse, "recur"),
            ParamID(.pulse, "ratchet"), ParamID(.pulse, "dynamics"), ParamID(.pulse, "humanize"),
            ParamID(.melody, "dynamics"), ParamID(.melody, "motion"), ParamID(.melody, "repeat"),
            ParamID(.melody, "contour"), ParamID(.melody, "glide"), ParamID(.melody, "humanize"),
        ]
        XCTAssertTrue(defaultRoutings().allSatisfy { !discrete.contains($0.destination) })

        let engine = Engine(seed: 99)
        engine.evolution.evolutionRate = 0
        let a = engine.effectiveParams(voice: .chords, bar: 0, tension: 0.5)["register"]
        let b = engine.effectiveParams(voice: .chords, bar: 500, tension: 0.5)["register"]
        XCTAssertEqual(a, b, accuracy: 0.000_001,
                       "zero evolution must genuinely freeze time-based modulation")
    }
}
