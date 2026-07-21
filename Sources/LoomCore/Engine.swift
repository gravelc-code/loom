import Foundation

/// A snapshot of `state(t)` published after each generated bar — everything
/// the UI needs to make the evolution visible (creeping knobs, arc view,
/// now/next chord, motif strip, activity meters, field scope).
/// A note event reduced to what the UI's piano roll needs.
public struct NoteSummary: Sendable {
    public let voice: Voice
    public let note: Int
    public let velocity: Int
    public let startStep: Double
    public let durationSteps: Double

    public init(_ e: NoteEvent) {
        voice = e.voice
        note = e.note
        velocity = e.velocity
        startStep = e.soundingStep
        durationSteps = e.durationSteps
    }
}

public struct EngineSnapshot: Sendable {
    public var bar: Int = 0
    public var tempo: Double = 84
    public var section: Section = .intro
    public var sectionBar: Int = 0
    public var sectionLength: Int = 8
    public var tension: Double = 0
    public var horizon: [(Section, Int)] = []
    public var formProfile: FormProfile = .slowBurn
    public var arrangementPreview: [ArrangementPreviewBar] = []
    public var chordLabel: String = "—"
    public var nextChordLabel: String = "—"
    public var keyLabel: String = ""
    public var dialectLabel: String = ""
    public var grooveLabel: String = ""
    public var isChordChangeBar: Bool = true
    public var phraseLabel: String = ""
    public var phraseBar: Int = 0
    public var phraseBars: Int = 4
    public var cadenceLabel: String = ""
    public var focus: Voice = .melody
    public var pool: [Int] = []
    /// Numeric harmony for the wheel display — derived, non-authoritative
    /// (never fed back into generation, so no determinism impact).
    public var keyRoot: Int = 0
    public var keyScale: Scale = .minor
    public var homeKeyRoot: Int = 0
    public var homeScale: Scale = .minor
    public var chordPCs: [Int] = []
    public var nextChordPCs: [Int] = []
    public var scaleMask: [Bool] = Array(repeating: false, count: 12)
    /// Key-journey region index — the movement number.
    public var movement: Int = 0
    /// Arrangement event this bar ("drop"/"exhale"), empty otherwise.
    public var eventLabel: String = ""
    /// Watchdog/user intervention applied to this bar, empty otherwise.
    public var disruptionLabel: String = ""
    /// Short plain-language account of the most meaningful change this bar.
    public var causalLabel: String = ""
    public var activeCueLabel: String = ""
    public var queuedCueLabel: String = ""
    public var queuedCueBar: Int?
    /// Live anti-wallpaper scores, shown without exposing implementation detail.
    public var interest = InterestMetrics()
    public var baseParams: [Voice: [String: Double]] = [:]
    public var effectiveParams: [Voice: [String: Double]] = [:]
    public var active: [Voice: Bool] = [:]
    public var activity: [Voice: Double] = [:]   // events this bar, normalized
    /// The kit's continuous presence envelope 0…1 this bar.
    public var drumPresence: Double = 0
    public var fieldGrid: [Float] = []
    public var motifLog: [(bar: Int, cellID: Int?, isRecall: Bool)] = []
    public var motifCellIDs: [Int] = []
    /// Everything this bar emitted — the UI's piano roll.
    public var notes: [NoteSummary] = []

    public init() {}
}

/// Everything one generated bar produces: notes, CC lanes, and the UI
/// snapshot.
public struct BarOutput {
    public let events: [NoteEvent]
    public let controls: [CCEvent]
    public let snapshot: EngineSnapshot
}

/// The generative core. Owns all state; a near-pure function of
/// `(params(t), harmony(t), modulation(t), motifMemory, bar, rng)` per voice.
/// Not thread-safe by design — one owner (the scheduler thread) calls
/// `generateBar` sequentially; the UI reads published `EngineSnapshot`s.
public final class Engine {
    public private(set) var masterSeed: UInt64
    public private(set) var subSeeds: [Voice: UInt64] = [:]

    public var tempo: Double = 84
    public var params: [Voice: ParamSet] = [:]
    public var evolution = EvolutionControls()
    public var harmonyEngine: HarmonyEngine
    public var conductor: Conductor
    public var modulation: ModulationEngine
    public let motifMemory = MotifMemory()

    var feels: [Voice: Feel] = [:]
    var smoothedActivity: Double = 0
    /// Listens to what was just played and forces a structural event when
    /// the music has been bland too long. Sequential like smoothedActivity;
    /// reset by rewind().
    public let interest = InterestAnalyzer()
    /// Immediate performance gates. These do not alter seeds or parameters,
    /// so a solo/mute can be released without changing the piece underneath.
    public var muted: [Voice: Bool] = Dictionary(uniqueKeysWithValues:
        Voice.allCases.map { ($0, false) })
    public var soloed: Voice?
    /// Last seen journey region — a change is a movement boundary (fade the
    /// oldest motifs). Sequential like MotifMemory; reset by rewind().
    var lastSeenRegion = 0
    /// Notes still ringing into the next bar (absolute end step), so the bass
    /// consonance pass can clear a new bass note against a pad swell or a long
    /// root that carries over a bar line. `sustained` marks drone/chords/bass
    /// tones, whose low whole-tone also beats. Sequential like smoothedActivity;
    /// reset by rewind(). Output-only — it never feeds harmony or the conductor.
    var ringingTails: [(note: Int, end: Double, sustained: Bool)] = []

    public init(seed: UInt64) {
        masterSeed = seed
        let home = HarmonyEngine.seededHome(seed: seed)
        harmonyEngine = HarmonyEngine(key: home.key, scale: home.scale, seed: seed)
        conductor = Conductor(seed: seed)
        modulation = ModulationEngine(seed: seed)
        for v in Voice.allCases {
            params[v] = Defaults.params(for: v)
            subSeeds[v] = hashSeed(seed, UInt64(Voice.allCases.firstIndex(of: v)!) &+ 0xB0)
            feels[v] = Feel(seed: seed, voice: v)
        }
    }

    /// Rewind to bar 0: reset the sequential state (field, motif memory,
    /// activity). With the same seed the piece replays identically and keeps
    /// evolving the same way.
    public func rewind() {
        modulation.field.reset()
        motifMemory.reset()
        smoothedActivity = 0
        lastSeenRegion = 0
        ringingTails = []
        interest.reset()
    }

    /// A full copy of the engine's sequential state at the current bar — the
    /// six items that `rewind()` resets. Everything else (harmony, conductor,
    /// drone spans, modulation LFOs/walks) is a pure function of seed+bar and
    /// needs no capture. Used to generate a display-only lookahead and then
    /// restore, so real playback continues byte-identically.
    struct SequentialSnapshot {
        var smoothedActivity: Double
        var lastSeenRegion: Int
        var ringingTails: [(note: Int, end: Double, sustained: Bool)]
        var motif: MotifMemory.State
        var interest: InterestAnalyzer.State
        var field: Field.State
    }
    func captureSequentialState() -> SequentialSnapshot {
        SequentialSnapshot(
            smoothedActivity: smoothedActivity, lastSeenRegion: lastSeenRegion,
            ringingTails: ringingTails, motif: motifMemory.captureState(),
            interest: interest.captureState(), field: modulation.field.captureState())
    }
    func restore(_ s: SequentialSnapshot) {
        smoothedActivity = s.smoothedActivity
        lastSeenRegion = s.lastSeenRegion
        ringingTails = s.ringingTails
        motifMemory.restore(s.motif)
        interest.restore(s.interest)
        modulation.field.restore(s.field)
    }

    /// Generate `count` bars starting at `fromBar` for DISPLAY ONLY, without
    /// disturbing the live timeline. Bars are produced in order (the field and
    /// activity follower feed `effectiveParams`, so you cannot skip ahead),
    /// then the sequential state is restored. Deterministic: with unchanged
    /// controls these are exactly the notes real playback will later generate.
    public func previewBars(fromBar: Int, count: Int) -> [[NoteSummary]] {
        guard count > 0 else { return [] }
        let saved = captureSequentialState()
        var out: [[NoteSummary]] = []
        out.reserveCapacity(count)
        for b in fromBar..<(fromBar + count) {
            out.append(generateBar(b).snapshot.notes)
        }
        restore(saved)
        return out
    }

    /// Start over with a new master seed: new progression, new modulation
    /// character, new sub-seeds. Keeps user params and evolution controls.
    public func reseed(_ seed: UInt64) {
        masterSeed = seed
        let dialectOverride = harmonyEngine.dialectOverride
        // A new seed is a new piece with a new home key/scale. The UI pulls the
        // new home back via refreshFromEngine; a loaded performance re-imposes
        // its saved key/scale after reseeding.
        let home = HarmonyEngine.seededHome(seed: seed)
        harmonyEngine = HarmonyEngine(key: home.key, scale: home.scale, seed: seed)
        harmonyEngine.dialectOverride = dialectOverride
        conductor = Conductor(seed: seed)
        modulation = ModulationEngine(seed: seed)
        for v in Voice.allCases {
            subSeeds[v] = hashSeed(seed, UInt64(Voice.allCases.firstIndex(of: v)!) &+ 0xB0)
            feels[v] = Feel(seed: seed, voice: v)
        }
        rewind()
    }

    /// Add a persisted, absolute-bar cue. A new cue replaces any future cue
    /// whose occupied interval overlaps it; already-started gestures survive.
    public func queueCue(_ kind: ArrangementCueKind, startBar: Int, currentBar: Int) {
        let cue = ArrangementCue(startBar: startBar, kind: kind)
        let newRange = cue.startBar..<(cue.startBar + cue.kind.occupiedBars)
        evolution.arrangementCues.removeAll { old in
            guard old.startBar > currentBar else { return false }
            let oldRange = old.startBar..<(old.startBar + old.kind.occupiedBars)
            return newRange.overlaps(oldRange)
        }
        evolution.arrangementCues.append(cue)
        evolution.arrangementCues.sort { $0.startBar < $1.startBar }
    }

    public func clearFutureCues(after bar: Int) {
        evolution.arrangementCues.removeAll { $0.startBar > bar }
    }

    /// `mutate`: perturb the seed's expression — re-roll unlocked voices'
    /// sub-seeds and nudge their parameters within musical bounds. Locked
    /// voices are untouched: freeze what you love, move the rest.
    public func mutate() {
        var m = masterSeed
        masterSeed = splitmix64(&m)
        var rng = RNG(seed: hashSeed(masterSeed, 0x4D55_5441))
        for v in Voice.allCases where !(evolution.locked[v] ?? false) {
            var s = subSeeds[v]!
            subSeeds[v] = splitmix64(&s)
            for name in params[v]!.names {
                params[v]![name] += rng.range(-0.08, 0.08)
            }
        }
    }

    /// Pattern-vocabulary seed for a voice: salted per journey region
    /// ("movement") so long runs keep freshening their material. Locked
    /// voices keep movement 0's vocabulary — freeze what you love.
    func materialSeed(for voice: Voice, movement: Int) -> UInt64 {
        let sub = subSeeds[voice]!
        guard movement > 0, !(evolution.locked[voice] ?? false) else { return sub }
        return hashSeed(sub, 0x4D56_4D54, UInt64(movement))
    }

    /// Effective (modulated) parameters for one voice at a bar.
    /// The per-voice `amount` knob as a tension bias for gates, density
    /// scaling and the drum presence target: ±0.4 around a neutral center.
    func amountBias(_ voice: Voice) -> Double {
        ((params[voice]?["amount"] ?? 0.5) - 0.5) * 0.8
    }

    /// Above center, the drums `amount` knob also promises a minimum kit
    /// presence — a groove that simply stays, instead of only visiting
    /// peaks. The mapping is steep (center→0, full→1) because presence is
    /// multiplied through the track ladder and density before any hit
    /// lands: a timid floor audibly vanishes.
    var drumPresenceFloor: Double {
        max(0, (params[.drums]?["amount"] ?? 0.5) - 0.5) * 2.0
    }

    func effectiveParams(voice: Voice, bar: Int, tension: Double,
                         focus: Voice? = nil, drumPresence: Double? = nil,
                         tensionBias: Double = 0) -> ParamSet {
        var p = params[voice]!
        guard !(evolution.locked[voice] ?? false) else { return p }
        // Evolution rate scales modulation time; conductor scales depth.
        let t = Double(bar) * (evolution.evolutionRate * 2.0)
        let depthScale = (evolution.drift[voice] ?? 0.5) * (0.5 + tension * 0.7)
        for name in p.names {
            let id = ParamID(voice, name)
            let off = modulation.offset(for: id, t: t, link: evolution.link, depthScale: depthScale)
            if off != 0 { p[name] = p[name] + off }
        }
        // Per-voice tension → density: the hierarchy of the arrangement.
        // Drums and bass barely exist below the develop band; chords stay a
        // bed; melody and drone pace themselves.
        switch voice {
        case .drums:
            // Density follows the kit's continuous presence envelope so it
            // swells in and fades out with the blend, not a tension cliff.
            let pres = drumPresence ?? smoothstep01((tension + tensionBias - 0.24) / 0.45)
            p["density"] = p["density"] * max(0.06, 0.15 + 0.85 * pres)
        case .bass:
            p["density"] = p["density"] * max(0, (tension + tensionBias - 0.30) / 0.70)
        case .chords:
            break
        case .pulse:
            p["density"] = p["density"] * max(0, (tension + tensionBias - 0.18) / 0.82)
        case .melody, .drone:
            break
        }
        // Performance energy is deliberately downstream of modulation and the
        // conductor. Center is transparent; either side continuously biases
        // density, and the melody gains/loses breathing room with it.
        let pushBias = (evolution.push - 0.5) * 0.7
        if p.values["density"] != nil { p["density"] += pushBias }
        if voice == .melody { p["rest"] -= pushBias * 0.55 }
        if let focus {
            if voice == focus {
                p["density"] = p["density"] + 0.08
            } else if voice != .drums && voice != .drone {
                p["density"] = p["density"] - 0.08
            }
        }
        return p
    }

    /// Generate one bar of music: note events and CC lanes (grid-relative to
    /// this bar) plus a snapshot for the UI.
    public func generateBar(_ bar: Int) -> BarOutput {
        let sectionBars = evolution.sectionBars
        let cues = evolution.arrangementCues
        conductor.transitions = evolution.transitions   // scales build/exhale length
        let cond = conductor.state(bar: bar, sectionBars: sectionBars, cues: cues)
        let tensionAt: (Int) -> Double = { [conductor] in
            conductor.state(bar: $0, sectionBars: sectionBars, cues: cues).tension
        }

        // Chord color blends conductor tension with the chords voice's own
        // tension knob.
        let chordTension = min(1, cond.tension * 0.68 + evolution.grit * 0.18)
        let harmony = harmonyEngine.context(atBar: bar, tension: chordTension,
                                            wander: evolution.wander, tensionAt: tensionAt,
                                            chromaticism: evolution.grit)
        let droneSpan = harmonyEngine.droneSpan(atBar: bar, wander: evolution.wander,
                                                tensionAt: tensionAt)

        // Claim the watchdog's verdict before building anything it may bend.
        // A conductor event wins the bar; a queued disruption waits for the
        // next clear bar instead of piling surprise on surprise.
        let disruption = cond.event == nil ? interest.takePending() : nil

        // The ensemble context: the shared rhythmic skeleton, motif material
        // and question → answer state every generator reads this bar.
        var sk = EnsembleContext.sketch(seed: masterSeed, bar: bar, tension: cond.tension)
        if disruption == .meterBreak {
            // Dissolve the shared skeleton for one bar: displace the
            // downbeat so every voice has to lean somewhere new.
            var mr = RNG(seed: hashSeed(masterSeed, 0x4D54_4252, UInt64(max(0, bar))))
            let shift = [2, 3, 6, 10][mr.int(4)]
            sk.anchors = Array(Set(sk.anchors.map { ($0 + shift) % stepsPerBar })).sorted()
            var gaps: [Range<Int>] = []
            for (i, a) in sk.anchors.enumerated() {
                let next = i + 1 < sk.anchors.count ? sk.anchors[i + 1] : stepsPerBar
                if next - a > 2 { gaps.append((a + 1)..<next) }
            }
            sk.gaps = gaps
        }
        var prevMelodyGesture = false
        if bar > 0 {
            let prevCond = conductor.state(bar: bar - 1, sectionBars: sectionBars, cues: cues)
            let prevSk = EnsembleContext.sketch(seed: masterSeed, bar: bar - 1,
                                                tension: prevCond.tension)
            prevMelodyGesture = prevCond.focus == .melody && prevSk.speaking
                && (prevCond.active[.melody] ?? false)
        }

        // The kit's continuous presence envelope: entries swell in over bars,
        // exits thin and fade instead of vanishing. The drums `amount` knob
        // biases its target so the kit can be invited in earlier (or held
        // back) regardless of where the conductor's arc sits.
        let drumBias = amountBias(.drums)
        let drumFloor = drumPresenceFloor
        let drumPresence = conductor.drumPresence(bar: bar, sectionBars: sectionBars,
                                                  tensionBias: drumBias,
                                                  presenceFloor: drumFloor, cues: cues)
        let nextDrumPresence = conductor.drumPresence(bar: bar + 1, sectionBars: sectionBars,
                                                      tensionBias: drumBias,
                                                      presenceFloor: drumFloor, cues: cues)

        // Arrangement events override the gates. Build → vacuum → drop is a
        // contrast gesture: climb, remove the floor, then land collectively.
        var activeGate = cond.active
        switch cond.event {
        case .build:
            activeGate[.drums] = true
            activeGate[.melody] = true
            activeGate[.pulse] = true
        case .vacuum:
            for v in Voice.allCases { activeGate[v] = v == .drone || v == .melody }
        case .drop:
            for v in Voice.allCases { activeGate[v] = true }
        case .exhale:
            for v in Voice.allCases where v != .drone && v != .chords { activeGate[v] = false }
        case nil:
            break
        }
        // A releasing kit tail is never guillotined by a gate flip (or an
        // exhale — it fades through it). A vacuum has presence 0; a drop 1.
        activeGate[.drums] = (activeGate[.drums] ?? false) || drumPresence > 0.02
        // The pitched voices' `amount` knobs bias their gates the same way:
        // turned up, a voice joins below its conductor threshold; turned
        // down, it sits out until tension earns it. Events keep overriding.
        if cond.event == nil {
            for v in [Voice.bass, .chords, .melody, .pulse] {
                let bias = amountBias(v)
                guard bias != 0 else { continue }
                let threshold = Conductor.activityThreshold(for: v)
                if bias > 0 && cond.tension + bias >= threshold { activeGate[v] = true }
                if bias < 0 && cond.tension + bias < threshold { activeGate[v] = false }
            }
        }
        // Master energy can invite voices in early or ask them to leave more
        // room, without rewriting the conductor's deterministic plan.
        let pushBias = (evolution.push - 0.5) * 0.7
        if cond.event == nil && pushBias != 0 {
            for v in [Voice.drums, .bass, .chords, .melody, .pulse] {
                let threshold = Conductor.activityThreshold(for: v)
                if pushBias > 0 && cond.tension + pushBias >= threshold { activeGate[v] = true }
                if pushBias < 0 && cond.tension + pushBias < threshold { activeGate[v] = false }
            }
        }

        // One-bar interventions are intentionally legible and reversible.
        switch disruption {
        case .silence:
            for v in Voice.allCases where v != .drone { activeGate[v] = false }
        case .solo:
            var sr = RNG(seed: hashSeed(masterSeed, 0x534F_4C4F, UInt64(max(0, bar))))
            let foreground: [Voice] = [.bass, .chords, .pulse, .melody, .drums]
            let chosen = foreground[sr.int(foreground.count)]
            for v in Voice.allCases { activeGate[v] = v == chosen }
        case .stutter:
            for v in Voice.allCases { activeGate[v] = v == .drums }
        case nil, .hush, .swell, .registerLeap, .harmonicBite, .meterBreak:
            break
        }

        // User performance gates have the final say.
        if let soloed {
            for v in Voice.allCases { activeGate[v] = v == soloed }
        }
        for v in Voice.allCases where muted[v] ?? false { activeGate[v] = false }
        let chordCenter = 48 + Int((params[.chords]!["register"] * 24).rounded())
        let chordSpread = params[.chords]!["spread"]
        // Loop tails ringing at a bar's start — pure function, so the pad
        // can see (and avoid) what the loop layer is already sustaining.
        let melodyRegister = effectiveParams(voice: .melody, bar: bar,
                                             tension: cond.tension,
                                             focus: cond.focus)["register"]
        let melodyShift = Int(((melodyRegister - 0.27) * 30).rounded())
        let melodyLoops = LoopPattern.bank(subSeed: materialSeed(for: .melody,
                                                                movement: harmony.regionIndex))
        func loopRing(atBar b: Int) -> [Int] {
            let clamped = max(0, b)
            let active: [LoopPattern] = [melodyLoops[0]]
            var ring: [Int] = []
            for p in active {
                if let pc = p.ringingPC(at: clamped * stepsPerBar, pool: harmony.pool) {
                    let raw = (p.octave + 1) * 12 + pc + melodyShift
                    ring.append(harmony.snapToChord(raw))
                }
            }
            return ring
        }
        let prevChordStart = bar - harmony.barInChord
            - (harmony.stepIndex > 0 ? harmony.phraseStepBars[harmony.stepIndex - 1] : 0)
        // The drone's actual sounding pitches, so the bass can clear a clash in
        // absolute pitch (a high register lifts the drone out of the low band).
        // The drone note was fixed when the span was emitted, so recompute its
        // params at the span's start bar — mid-span register drift would
        // otherwise report a phantom pitch the drone never sounded.
        let droneStartCond = conductor.state(bar: droneSpan.startBar,
                                             sectionBars: sectionBars, cues: cues)
        let droneEff = effectiveParams(voice: .drone, bar: droneSpan.startBar,
                                       tension: droneStartCond.tension,
                                       focus: droneStartCond.focus, drumPresence: nil,
                                       tensionBias: amountBias(.drone))
        let ensemble = EnsembleContext(
            anchors: sk.anchors, gaps: sk.gaps, focus: cond.focus, speaking: sk.speaking,
            prevMelodyGesture: prevMelodyGesture, motifCell: motifMemory.cells.last,
            chordVoicing: ChordGenerator.spaced(
                ChordGenerator.voicedChord(upTo: harmony.stepIndex, in: harmony,
                                           center: chordCenter),
                spread: chordSpread),
            droneRootPC: droneSpan.rootPC,
            droneNotes: DroneGenerator.notes(span: droneSpan, params: droneEff),
            ringingLoopNotes: loopRing(atBar: bar),
            prevChordRinging: loopRing(atBar: prevChordStart))

        // Movement boundary: a new journey region retires the oldest motifs
        // so the new key gets fresh material.
        let movementChanged = bar > 0 && harmony.regionIndex != lastSeenRegion
        if movementChanged {
            motifMemory.fade()
        }
        lastSeenRegion = harmony.regionIndex

        modulation.stepFieldForBar()
        modulation.activity = smoothedActivity

        // Fill amount: rises across the last two bars of a section.
        let barsLeft = cond.sectionLength - cond.sectionBar - 1
        var fill = barsLeft == 0 ? 0.9 : (barsLeft == 1 ? 0.45 : 0.0)
        if cond.event == .build { fill = max(fill, 0.68) }
        if cond.event == .drop { fill = 0 }

        var all: [NoteEvent] = []
        var perVoiceCount: [Voice: Int] = [:]

        for voice in Voice.allCases {
            guard activeGate[voice] ?? true else { perVoiceCount[voice] = 0; continue }
            var p = effectiveParams(voice: voice, bar: bar, tension: cond.tension,
                                    focus: cond.focus,
                                    drumPresence: voice == .drums ? drumPresence : nil,
                                    tensionBias: amountBias(voice))
            if disruption == .stutter && voice == .drums {
                p["density"] = 0.9
                p["ratchet"] = 1
                p["fills"] = 1
            }
            if cond.event == .build {
                switch voice {
                case .drums:
                    p["density"] = max(p["density"], 0.72)
                    p["ratchet"] = max(p["ratchet"], 0.62)
                    p["fills"] = max(p["fills"], 0.8)
                case .melody:
                    p["repeat"] = max(p["repeat"], 0.78)
                    p["rest"] = max(p["rest"], 0.58)
                case .chords:
                    break
                case .pulse:
                    p["density"] = max(p["density"], 0.72)
                    p["division"] = max(p["division"], cond.sectionBar == cond.sectionLength - 2 ? 0.72 : 0.52)
                    p["ratchet"] = max(p["ratchet"], 0.48)
                case .bass, .drone: break
                }
            } else if cond.event == .drop {
                switch voice {
                case .drums:
                    p["density"] = max(p["density"], 0.82)
                    p["dynamics"] = max(p["dynamics"], 0.82)
                case .bass:
                    p["density"] = max(p["density"], 0.72)
                    p["accent"] = 1
                case .chords:
                    break
                case .melody:
                    p["rest"] = max(p["rest"], 0.68)
                case .pulse:
                    p["density"] = max(p["density"], 0.62)
                    p["dynamics"] = max(p["dynamics"], 0.78)
                case .drone: break
                }
            }
            if cond.section == .breakdown {
                switch voice {
                case .chords:
                    p["register"] = max(0, p["register"] - 0.15)
                case .melody:
                    p["rest"] = max(p["rest"], 0.78)
                    p["register"] = max(0, p["register"] - 0.24)
                case .pulse:
                    p["density"] = min(p["density"], 0.16)
                    p["octave"] = max(0, p["octave"] - 0.2)
                case .drums, .bass, .drone: break
                }
            }
            let sub = subSeeds[voice]!
            let feel = feels[voice]!
            var events: [NoteEvent]
            switch voice {
            case .drums:
                events = DrumGenerator.generate(bar: bar, params: p, subSeed: sub,
                                                profileSeed: materialSeed(for: .drums,
                                                                          movement: harmony.regionIndex),
                                                feel: feel, fill: fill, tension: cond.tension,
                                                presence: drumPresence,
                                                nextPresence: nextDrumPresence,
                                                anchors: ensemble.anchors,
                                                accentDownbeat: cond.event == .drop
                                                    || (harmony.barInPhrase == 0 && bar > 0
                                                        && drumPresence >= 0.6),
                                                friction: evolution.grit,
                                                styleOverride: evolution.grooveStyle,
                                                section: cond.section, event: cond.event,
                                                buildProgress: cond.buildProgress,
                                                dialect: harmonyEngine.dialect)
            case .bass:
                events = BassGenerator.generate(bar: bar, params: p, harmony: harmony,
                                                subSeed: sub, feel: feel,
                                                tension: cond.tension,
                                                isFocus: cond.focus == .bass,
                                                ensemble: ensemble)
            case .chords:
                events = ChordGenerator.generate(bar: bar, params: p, harmony: harmony,
                                                 subSeed: sub, feel: feel,
                                                 tension: cond.tension, ensemble: ensemble)
            case .melody:
                events = MelodyGenerator.generate(bar: bar, params: p, harmony: harmony,
                                                  subSeed: sub,
                                                  bankSeed: materialSeed(for: .melody,
                                                                         movement: harmony.regionIndex),
                                                  feel: feel, memory: motifMemory,
                                                  recurrence: evolution.motifRecurrence,
                                                  tension: cond.tension, ensemble: ensemble)
            case .drone:
                events = DroneGenerator.generate(bar: bar, params: p, span: droneSpan,
                                                 tension: cond.tension)
            case .pulse:
                events = PulseGenerator.generate(bar: bar, params: p, harmony: harmony,
                                                 subSeed: sub, feel: feel,
                                                 tension: cond.tension, ensemble: ensemble,
                                                 event: cond.event, friction: evolution.grit)
            }
            // Velocity hierarchy: the focus voice leans forward, the drone
            // holds its level, everyone else recedes.
            let velScale: Double = voice == cond.focus ? 1.12 : (voice == .drone ? 1.0 : 0.8)
            if velScale != 1.0 {
                for i in events.indices {
                    events[i].velocity = min(127, max(1, Int(Double(events[i].velocity) * velScale)))
                }
            }
            if cond.event == .exhale && voice == .drums {
                for i in events.indices { events[i].velocity = min(88, events[i].velocity) }
            }
            if disruption == .registerLeap {
                for i in events.indices {
                    if voice == .melody { events[i].note += 12 }
                    if voice == .bass { events[i].note -= 12 }
                }
            }
            if disruption == .hush || disruption == .swell {
                let eventScale = disruption == .hush ? 0.48 : 1.28
                for i in events.indices {
                    events[i].velocity = min(127, max(1,
                        Int((Double(events[i].velocity) * eventScale).rounded())))
                }
            }
            // Groove signature: the piece's role-asymmetric pocket, applied
            // on top of the per-event Feel noise (constrain clamps to ±0.4).
            let groove = GrooveSignature(seed: sub)
            for i in events.indices {
                events[i].timingOffset += groove.offset(
                    voice: voice,
                    drumNote: voice == .drums ? events[i].note : nil,
                    tension: cond.tension,
                    absoluteStep: Double(bar * stepsPerBar) + events[i].startStep)
            }
            constrain(&events, voice: voice, harmony: harmony)
            perVoiceCount[voice] = events.count
            all += events
        }

        // A harmonic bite is always an approach-and-resolution gesture, never
        // an unaccountable wrong note: a short chromatic neighbor leans into a
        // real melody note and disappears before the target sounds.
        if disruption == .harmonicBite {
            // A sparse melody may be resting on the requested bar. In that
            // case the intervention supplies its own quiet chord-tone target
            // so the chromatic neighbor is still heard *as an approach*, not
            // as an isolated wrong note.
            let target: NoteEvent
            if let existing = all.first(where: {
                $0.voice == .melody && $0.startStep >= 0.5
            }) {
                target = existing
            } else {
                target = NoteEvent(voice: .melody,
                                   note: harmony.snapToChord(72),
                                   velocity: 52, startStep: 8,
                                   durationSteps: 2)
                all.append(target)
                perVoiceCount[.melody, default: 0] += 1
            }
            var br = RNG(seed: hashSeed(masterSeed, 0x4249_5445, UInt64(max(0, bar))))
            let candidates = [target.note - 1, target.note + 1].filter { note in
                let pc = ((note % 12) + 12) % 12
                return note >= 55 && note <= 100 && !harmony.latticeMask[pc]
            }
            let neighbor = candidates.isEmpty
                ? min(100, max(55, target.note + (br.chance(0.5) ? 1 : -1)))
                : candidates[br.int(candidates.count)]
            all.append(NoteEvent(voice: .melody, note: neighbor,
                                 velocity: max(24, Int(Double(target.velocity) * 0.62)),
                                 startStep: target.startStep - 0.5,
                                 durationSteps: 0.38))
            perVoiceCount[.melody, default: 0] += 1
        }

        // Bass consonance: with every voice now realized, lift a monophonic
        // bass note off any sustained semitone against the drone, the pad, the
        // melody or a bass root carried over from the previous bar. This is the
        // one clearance that needs the whole ensemble, so it runs last.
        let bassDropped = resolveBassConsonance(&all, bar: bar, droneNotes: ensemble.droneNotes)
        if bassDropped > 0 {
            perVoiceCount[.bass] = max(0, (perVoiceCount[.bass] ?? 0) - bassDropped)
        }

        // Feed the watchdog what actually survived gates and constraints. The
        // bit mask lets it distinguish lawful color from deliberate chromatic
        // tension without changing the harmony engine itself.
        var latticeBits: UInt16 = 0
        for pc in 0..<min(12, harmony.latticeMask.count) where harmony.latticeMask[pc] {
            latticeBits |= UInt16(1) << UInt16(pc)
        }
        interest.observe(bar: bar, events: all, chordRoot: harmony.chord.rootPC,
                         pool: harmony.pool, latticeMask: latticeBits,
                         hadSectionEvent: cond.event != nil || disruption != nil,
                         grit: evolution.grit, seed: masterSeed)

        // Activity follower: smoothed *tonal* density feeds reactive routings
        // next bar. Drums are excluded — now that the kit sustains for minutes,
        // counting it would permanently thin the melodic voices that are meant
        // to be the foreground over a steady drum bed.
        let raw = min(1.0, Double(all.filter { $0.voice != .drums }.count) / 36.0)
        smoothedActivity = smoothedActivity * 0.7 + raw * 0.3

        // CC lanes: sample the modulation sources across the bar for every
        // active voice. The full sample set is emitted (deterministic);
        // the transport layer deduplicates repeats.
        var controls: [CCEvent] = []
        let rate = evolution.evolutionRate * 2.0
        let droneSwell = effectiveParams(voice: .drone, bar: bar,
                                         tension: cond.tension)["swell"]
        for voice in Voice.allCases where activeGate[voice] ?? true {
            for k in 0..<ControlLanes.samplesPerBar {
                let step = Double(k * stepsPerBar) / Double(ControlLanes.samplesPerBar)
                let t = (Double(bar) + step / Double(stepsPerBar)) * rate
                controls.append(CCEvent(voice: voice,
                                        controller: ControlLanes.tensionController,
                                        value: min(127, max(0, Int((cond.tension * 127).rounded()))),
                                        startStep: step))
                let phrasePhase = min(1, max(0,
                    (Double(harmony.barInPhrase) + step / Double(stepsPerBar))
                        / Double(max(1, harmony.phraseBars))))
                let breath = 0.55 + 0.45 * sin(phrasePhase * .pi)
                let expression: Double
                switch voice {
                case .drone: expression = 0.58 + breath * 0.28
                case .chords: expression = 0.38 + breath * 0.48
                case .melody: expression = 0.42 + breath * 0.35 + cond.tension * 0.16
                case .bass: expression = 0.48 + cond.tension * 0.30
                case .drums: expression = 0.46 + drumPresence * 0.42
                case .pulse: expression = 0.40 + breath * 0.26 + cond.tension * 0.24
                }
                controls.append(CCEvent(voice: voice,
                                        controller: ControlLanes.expressionController,
                                        value: min(127, max(0, Int((expression * 127).rounded()))),
                                        startStep: step))
                // Textural transition automation — the ambient toolkit: slow
                // filter movement, reverb swells and a gentle section-bridge
                // swell. No EDM riser or impact snaps; everything glides. The
                // `transitions` macro scales how pronounced these moves are.
                let sp = step / Double(stepsPerBar)
                let exB = max(1, conductor.exhaleBars())
                let depth = evolution.transitions
                let sectionPhase = (Double(cond.sectionBar) + sp)
                    / Double(max(1, cond.sectionLength))

                // Filter-sweep — CC 74: opens gradually with the tension arc,
                // closes through quiet passages. Slow and continuous.
                let brightness = min(1, max(0,
                    0.20 + cond.tension * 0.55 + evolution.grit * 0.18))
                controls.append(CCEvent(voice: voice,
                                        controller: ControlLanes.brightnessController,
                                        value: Int((brightness * 127).rounded()),
                                        startStep: step))

                // Bridge swell — CC 25: a slow rise across the final third of a
                // section into the boundary (map to a pad / reverse-reverb swell
                // that carries one section into the next).
                let swell = (sectionPhase > 0.66
                    ? smoothstep01((sectionPhase - 0.66) / 0.34) : 0) * (0.4 + 0.6 * depth)
                controls.append(CCEvent(voice: voice,
                                        controller: ControlLanes.transitionController,
                                        value: Int((swell * 127).rounded()),
                                        startStep: step))

                // Downlift — CC 26: a gentle fall as a peak dissolves into a
                // breakdown (map to a downlifter / a filter easing shut).
                var downlift = 0.0
                if cond.event == .exhale {
                    downlift = 0.6 * (1 - Double(cond.sectionBar) / Double(exB))
                } else if cond.section == .breakdown {
                    downlift = 0.3 * (1 - cond.tension)
                }
                downlift *= (0.4 + 0.6 * depth)
                controls.append(CCEvent(voice: voice,
                                        controller: ControlLanes.dropAccentController,
                                        value: Int((min(1, downlift) * 127).rounded()),
                                        startStep: step))

                // Reverb-wash — CC 27: swells in the sparse, quiet passages
                // (breakdowns, intros) and pulls back when the mix fills. The
                // ambient "reverb throw" that glues sections together.
                var wash = 0.18 + (1 - cond.tension) * 0.5
                if cond.section == .breakdown || cond.section == .intro { wash += 0.15 }
                if cond.event == .exhale { wash += 0.15 * (1 - sp) }
                wash = 0.15 + (min(1, wash) - 0.15) * (0.5 + 0.5 * depth)
                controls.append(CCEvent(voice: voice,
                                        controller: ControlLanes.reverbWashController,
                                        value: min(127, max(0, Int((wash * 127).rounded()))),
                                        startStep: step))
                for lane in ControlLanes.sourceLanes {
                    let v = modulation.value(lane.source, t: t, voice: voice, link: evolution.link)
                    controls.append(CCEvent(voice: voice, controller: lane.controller,
                                            value: ControlLanes.quantize(v), startStep: step))
                }
                if voice == .drone {
                    // CC24: a triangle over the whole drone span — map it to
                    // filter cutoff and the pad breathes with the harmony.
                    let phase = (Double(bar - droneSpan.startBar) + step / Double(stepsPerBar))
                        / Double(max(1, droneSpan.bars))
                    let tri = 1 - abs(2 * min(1, max(0, phase)) - 1)
                    controls.append(CCEvent(voice: .drone,
                                            controller: ControlLanes.swellController,
                                            value: min(127, max(0, Int((tri * droneSwell * 127).rounded()))),
                                            startStep: step))
                }
            }
        }

        var snap = EngineSnapshot()
        snap.bar = bar
        snap.tempo = tempo
        snap.section = cond.section
        snap.sectionBar = cond.sectionBar
        snap.sectionLength = cond.sectionLength
        snap.tension = cond.tension
        snap.horizon = cond.horizon
        snap.formProfile = conductor.profile
        snap.arrangementPreview = conductor.preview(startBar: bar, count: 32,
                                                     sectionBars: sectionBars,
                                                     cues: cues)
        snap.chordLabel = "\(noteNames[harmony.chord.rootPC])\(chordQuality(harmony.chord)) (\(harmony.chord.label))"
        snap.nextChordLabel = "\(noteNames[harmony.nextChord.rootPC])\(chordQuality(harmony.nextChord))"
        let sounding = "\(noteNames[harmony.key]) \(harmony.scale.rawValue)"
        snap.keyLabel = (harmony.key == harmonyEngine.key && harmony.scale == harmonyEngine.scale)
            ? sounding
            : "\(sounding) · home \(noteNames[harmonyEngine.key]) \(harmonyEngine.scale.rawValue)"
        snap.dialectLabel = harmonyEngine.dialect.rawValue
        snap.grooveLabel = DrumGenerator.style(
            profileSeed: materialSeed(for: .drums, movement: harmony.regionIndex),
            override: evolution.grooveStyle).rawValue
        snap.movement = harmony.regionIndex
        snap.keyRoot = harmony.key
        snap.keyScale = harmony.scale
        snap.homeKeyRoot = harmonyEngine.key
        snap.homeScale = harmonyEngine.scale
        snap.chordPCs = harmony.chord.pitchClasses
        snap.nextChordPCs = harmony.nextChord.pitchClasses
        snap.scaleMask = harmony.scaleMask
        snap.isChordChangeBar = harmony.isChordChangeBar
        snap.phraseLabel = harmony.phraseName
        snap.phraseBar = harmony.barInPhrase
        snap.phraseBars = harmony.phraseBars
        snap.cadenceLabel = harmony.cadence == .none ? "" : harmony.cadence.rawValue
        snap.active = activeGate
        snap.focus = cond.focus
        snap.pool = harmony.pool
        snap.eventLabel = cond.event?.rawValue ?? ""
        if let activeCue = cues.last(where: {
            bar >= $0.startBar && bar < $0.startBar + $0.kind.occupiedBars
        }) {
            snap.activeCueLabel = activeCue.kind.rawValue
        }
        if let queued = cues.filter({ $0.startBar > bar }).min(by: { $0.startBar < $1.startBar }) {
            snap.queuedCueLabel = queued.kind.rawValue
            snap.queuedCueBar = queued.startBar
        }
        snap.disruptionLabel = disruption?.label ?? ""
        snap.interest = interest.metrics
        if let disruption {
            snap.causalLabel = "\(disruption.label) · interest \(String(format: "%.2f", interest.metrics.overall))"
        } else if let event = cond.event {
            snap.causalLabel = "\(event.rawValue) · conductor"
        } else if movementChanged {
            snap.causalLabel = "movement \(harmony.regionIndex + 1) · new material"
        } else if let last = motifMemory.recallLog.last, last.bar == bar, let transform = last.transform {
            snap.causalLabel = "motif \(last.cellID ?? 0) · \(transform.rawValue)"
        } else {
            snap.causalLabel = "\(harmony.phraseName) · \(cond.focus.rawValue) in focus"
        }
        snap.drumPresence = drumPresence
        for v in Voice.allCases {
            snap.baseParams[v] = params[v]!.values
            snap.effectiveParams[v] = effectiveParams(voice: v, bar: bar, tension: cond.tension,
                                                      focus: cond.focus,
                                                      drumPresence: v == .drums ? drumPresence : nil,
                                                      tensionBias: amountBias(v)).values
            let maxCount: Double = v == .drums ? 24
                : (v == .chords ? 16 : (v == .drone ? 3 : (v == .pulse ? 12 : 10)))
            snap.activity[v] = min(1, Double(perVoiceCount[v] ?? 0) / maxCount)
        }
        snap.fieldGrid = modulation.field.grid
        snap.motifLog = motifMemory.recallLog.map { ($0.bar, $0.cellID, $0.transform != nil) }
        snap.motifCellIDs = motifMemory.cells.map { $0.id }
        snap.notes = all.map(NoteSummary.init)
        return BarOutput(events: all, controls: controls, snapshot: snap)
    }

    func chordQuality(_ chord: Chord) -> String {
        guard chord.pitchClasses.count >= 3 else { return "" }
        if chord.label.hasSuffix("sus2") { return "sus2" }
        let third = (chord.pitchClasses[1] - chord.pitchClasses[0] + 12) % 12
        let fifth = (chord.pitchClasses[2] - chord.pitchClasses[0] + 12) % 12
        if third == 3 && fifth == 6 { return "dim" }
        switch third {
        case 3: return "m"
        case 4: return ""
        case 5: return "sus"
        default: return "?"
        }
    }

    /// Constraint pass: snap pitched voices to the lattice (scale ∪ chord),
    /// clamp range, keep micro-timing from pulling events off their grid
    /// anchor, and de-collide simultaneous same-pitch notes within a voice.
    /// Chords are exempt from pitch snapping — their voicings are chord tones
    /// by construction, and re-snapping would wreck the voice leading.
    /// Clear the monophonic bass of sustained semitone rubs against everything
    /// else sounding — this bar's realized voices, the sustaining drone, and
    /// any pad swell or bass root ringing over from the previous bar. A high
    /// drone plus a wide pad can fill the low band, so the pass first tries to
    /// move the bass to the octave of its pitch class that shares the fewest
    /// beats (a semitone counts double; a low whole-tone against a sustained
    /// tone counts once). If nothing clears and the note is long enough to beat
    /// audibly, it is silenced instead — the drone holds the low end and space
    /// is ambient-correct. Output-only and deterministic: it depends only on
    /// this bar's notes plus `ringingTails`, which rewind() clears; a note that
    /// already clears is left exactly where it is.
    @discardableResult
    func resolveBassConsonance(_ all: inout [NoteEvent], bar: Int, droneNotes: [Int]) -> Int {
        let base = Double(bar * stepsPerBar)
        let barEnd = base + Double(stepsPerBar)
        let bassRange = 24...60
        struct Ringing { let lo: Double; let hi: Double; let note: Int; let sustained: Bool }
        var others: [Ringing] = []
        for ev in all where ev.voice != .bass {
            let lo = base + ev.startStep
            others.append(Ringing(lo: lo, hi: lo + ev.durationSteps, note: ev.note,
                                  sustained: ev.voice == .drone || ev.voice == .chords))
        }
        // The drone sustains across the whole bar even when it re-attacks
        // elsewhere; pad swells and long bass roots carry over the bar line.
        for d in droneNotes { others.append(Ringing(lo: base, hi: barEnd, note: d, sustained: true)) }
        for t in ringingTails where t.end > base {
            others.append(Ringing(lo: base, hi: t.end, note: t.note, sustained: t.sustained))
        }

        var toRemove: [Int] = []
        for i in all.indices where all[i].voice == .bass {
            let lo = base + all[i].startStep
            let hi = lo + all[i].durationSteps
            // Only pitches that genuinely overlap (a shared step or more).
            let concurrent = others.filter { $0.hi > lo + 0.5 && $0.lo < hi - 0.5 }
            guard !concurrent.isEmpty else { continue }
            func score(_ x: Int) -> Int {
                var s = 0
                for c in concurrent {
                    let a = abs(c.note - x)
                    if a == 1 { s += 2 } else if a == 2 && c.sustained { s += 1 }
                }
                return s
            }
            let here = all[i].note
            guard score(here) > 0 else { continue }
            let pc = ((here % 12) + 12) % 12
            let candidates = stride(from: bassRange.lowerBound, through: bassRange.upperBound, by: 1)
                .filter { ((($0 % 12) + 12) % 12) == pc }
            let best = candidates.min(by: {
                (score($0), abs($0 - here)) < (score($1), abs($1 - here))
            }) ?? here
            // A remaining semitone on a note long enough to beat is worse than a
            // rest — drop it. Short bass touches ride out as passing friction.
            if score(best) > 0 && all[i].durationSteps > 1.0 {
                toRemove.append(i)
            } else {
                all[i].note = best
            }
        }
        for i in toRemove.reversed() { all.remove(at: i) }

        // Carry still-ringing pad and bass tails to the next bar so a swell or
        // root sustaining several bars keeps clearing every downbeat under it —
        // accumulate, don't overwrite, or a multi-bar swell is lost after one.
        var carried = ringingTails.filter { $0.end > barEnd }
        carried += all.filter {
            ($0.voice == .chords || $0.voice == .bass)
                && base + $0.startStep + $0.durationSteps > barEnd
        }.map { (note: $0.note, end: base + $0.startStep + $0.durationSteps,
                 sustained: true) }
        ringingTails = carried
        return toRemove.count
    }

    func constrain(_ events: inout [NoteEvent], voice: Voice, harmony: HarmonyContext) {
        guard voice != .drums else {
            for i in events.indices {
                events[i].timingOffset = max(-0.4, min(0.4, events[i].timingOffset))
            }
            return
        }
        let range: ClosedRange<Int>
        switch voice {
        case .bass:   range = 24...55
        case .chords: range = 36...94   // wide enough for the register slider
        case .melody: range = 55...100  // above the bed — no melody in the mud
        case .drone:  range = 24...52
        case .pulse:  range = 55...92
        default:      range = 0...127
        }
        for i in events.indices {
            // Chords voice-lead their own chord tones; the drone's span root
            // is the fixed point — neither is re-snapped.
            let exempt = voice == .chords || voice == .drone
            var n = exempt ? events[i].note : harmony.snapToLattice(events[i].note)
            while n < range.lowerBound { n += 12 }
            while n > range.upperBound { n -= 12 }
            events[i].note = n
            events[i].timingOffset = max(-0.4, min(0.4, events[i].timingOffset))
        }
        // De-collide: identical pitch at (nearly) the same grid position.
        events.sort { ($0.startStep, $0.note) < ($1.startStep, $1.note) }
        var i = events.count - 1
        while i > 0 {
            if events[i].note == events[i - 1].note &&
                abs(events[i].startStep - events[i - 1].startStep) < 0.26 {
                events.remove(at: i)
            }
            i -= 1
        }
        // Trim overlaps for monophonic voices.
        if voice == .bass || voice == .melody || voice == .pulse {
            for i in 0..<max(0, events.count - 1) {
                let gap = events[i + 1].startStep - events[i].startStep
                if events[i].durationSteps > gap && !events[i].glide {
                    events[i].durationSteps = max(0.2, gap * 0.95)
                }
            }
        }
    }
}
