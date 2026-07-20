import Foundation

/// Clamped cubic smoothstep: 0 below the window, 1 above, eased inside.
func smoothstep01(_ x: Double) -> Double {
    let t = min(1, max(0, x))
    return t * t * (3 - 2 * t)
}

/// The macro brain: a section state machine (intro → develop → peak →
/// breakdown, probabilistic transitions) driving a tension value in [0, 1].
/// Tension scales global density, per-voice activity gates, modulation depth,
/// tension-type parameters, and harmonic rhythm. Deterministic from the seed,
/// so a seed reproduces a whole *shaped* piece.
public enum Section: String, CaseIterable, Sendable {
    case intro, develop, peak, breakdown

    /// Nominal length as a multiple of the user's section length. Ambient
    /// pacing: long intros and even longer develops; peaks are episodes.
    var lengthFactor: Double {
        switch self {
        case .intro: return 1.0
        case .develop: return 1.75
        case .peak: return 0.75
        case .breakdown: return 1.0
        }
    }

    /// Tension ramp endpoints across the section. The floor sits far lower
    /// than before — the piece lives in the drone-and-fragments zone and only
    /// peaks earn the kit.
    public var tensionRamp: (Double, Double) {
        switch self {
        case .intro: return (0.02, 0.18)
        case .develop: return (0.18, 0.68)
        case .peak: return (0.90, 0.76)
        case .breakdown: return (0.42, 0.05)
        }
    }

    /// Probabilistic next-section weights [intro, develop, peak, breakdown].
    var transitions: [Double] {
        switch self {
        case .intro: return [0.0, 1.0, 0.0, 0.0]
        case .develop: return [0.0, 0.30, 0.55, 0.15]
        case .peak: return [0.0, 0.10, 0.0, 0.90]
        case .breakdown: return [0.25, 0.70, 0.05, 0.0]
        }
    }
}

/// A seed chooses one guarded large-scale grammar. Profiles make different
/// pieces develop differently without permitting arbitrary section order:
/// every peak is prepared, every fall has somewhere quieter to land, and the
/// complete schedule remains random-access and deterministic.
public enum FormProfile: String, CaseIterable, Sendable, Codable {
    case slowBurn = "slow burn"
    case doublePeak = "double peak"
    case episodic
    case deepReset = "deep reset"
}

/// Arrangement events at section boundaries — how the macro form breathes.
public enum SectionEvent: String, Sendable {
    /// Penultimate bars before a peak: a repeated detail accelerates while
    /// energy and kit presence climb.
    case build
    /// The final pre-drop bar removes kick and low end. Contrast creates the
    /// impact; adding more notes would not.
    case vacuum
    /// First bar of a peak: the full ensemble lands together.
    case drop
    /// First bars of a breakdown after a peak: only drone and chords exhale.
    case exhale
}

public enum ArrangementCueKind: String, CaseIterable, Codable, Sendable {
    case buildDrop = "build → drop"
    case breakdown
    case nextSection = "next section"

    public var occupiedBars: Int {
        switch self {
        case .buildDrop: return 4
        case .breakdown, .nextSection: return 1
        }
    }
}

/// A user-authored bend in the otherwise autonomous section schedule.
/// Absolute-bar storage makes live curation rewindable and MIDI-exportable.
public struct ArrangementCue: Codable, Sendable, Equatable {
    public let startBar: Int
    public let kind: ArrangementCueKind

    public init(startBar: Int, kind: ArrangementCueKind) {
        self.startBar = max(0, startBar)
        self.kind = kind
    }
}

public struct ConductorState: Sendable {
    public let section: Section
    public let sectionBar: Int      // bars into the section
    public let sectionLength: Int   // bars in this section
    public let tension: Double      // 0...1
    /// Per-voice activity gate — is the voice playing at all this bar?
    public let active: [Voice: Bool]
    /// The one foreground voice this section — everyone else recedes.
    public let focus: Voice
    /// Arrangement event on this bar, if any.
    public let event: SectionEvent?
    /// Upcoming sections for the timeline view: (section, length in bars).
    public let horizon: [(Section, Int)]
}

/// One bar of the conductor's forward plan, reduced to the information a
/// compact arrangement strip needs. Absolute bars keep queued cues aligned.
public struct ArrangementPreviewBar: Sendable, Equatable {
    public let bar: Int
    public let section: Section
    public let tension: Double
    public let activeVoices: [Voice]
    public let event: SectionEvent?
    public let cue: ArrangementCueKind?

    public init(bar: Int, section: Section, tension: Double,
                activeVoices: [Voice], event: SectionEvent?,
                cue: ArrangementCueKind?) {
        self.bar = bar
        self.section = section
        self.tension = tension
        self.activeVoices = activeVoices
        self.event = event
        self.cue = cue
    }
}

public struct Conductor {
    let seed: UInt64
    public let profile: FormProfile

    public init(seed: UInt64) {
        self.seed = seed
        var rng = RNG(seed: hashSeed(seed, 0x464F_524D))
        profile = FormProfile.allCases[rng.pick([0.34, 0.26, 0.22, 0.18])]
    }

    private func nextSection(after section: Section, rng: inout RNG) -> Section {
        let weights: [Double]
        switch (profile, section) {
        case (_, .intro):
            weights = [0, 1, 0, 0]
        case (.slowBurn, .develop):
            weights = [0, 0.55, 0.40, 0.05]
        case (.doublePeak, .develop):
            weights = [0, 0.15, 0.75, 0.10]
        case (.episodic, .develop):
            weights = [0, 0.25, 0.35, 0.40]
        case (.deepReset, .develop):
            weights = [0, 0.25, 0.65, 0.10]
        case (.slowBurn, .peak), (.episodic, .peak), (.deepReset, .peak):
            weights = [0, 0, 0, 1]
        case (.doublePeak, .peak):
            weights = [0, 0.55, 0, 0.45]
        case (.slowBurn, .breakdown):
            weights = [0.20, 0.80, 0, 0]
        case (.doublePeak, .breakdown):
            weights = [0.10, 0.90, 0, 0]
        case (.episodic, .breakdown):
            weights = [0.20, 0.80, 0, 0]
        case (.deepReset, .breakdown):
            weights = [0.65, 0.35, 0, 0]
        }
        return Section.allCases[rng.pick(weights)]
    }

    private func lengthMultiplier(for section: Section) -> Double {
        switch (profile, section) {
        case (.slowBurn, .develop): return 1.25
        case (.doublePeak, .develop): return 0.78
        case (.doublePeak, .peak): return 0.72
        case (.doublePeak, .breakdown): return 0.68
        case (.episodic, _): return 0.82
        case (.deepReset, .breakdown): return 1.50
        case (.deepReset, .intro): return 0.82
        default: return 1
        }
    }

    /// The section schedule is a deterministic walk from bar 0; recomputed on
    /// demand (a handful of picks even for hours of music).
    func schedule(upTo bar: Int, sectionBars: Int) -> [(Section, Int)] {
        var rng = RNG(seed: hashSeed(seed, 0x5345_4354))
        var result: [(Section, Int)] = []
        var section = Section.intro
        var total = 0
        var extra = 0
        // Cover the requested bar, then keep going a few sections so the
        // timeline view can show what's coming next.
        while (total <= bar + 1 || extra < 3) && result.count < 512 {
            if total > bar + 1 { extra += 1 }
            let jitter = 0.75 + rng.unit() * 0.5
            // Quantized to 4-bar multiples so section boundaries (and the
            // fills that anticipate them) land on phrase boundaries.
            let raw = Double(sectionBars) * section.lengthFactor
                * lengthMultiplier(for: section) * jitter
            let len = max(4, Int((raw / 4).rounded()) * 4)
            result.append((section, len))
            total += len
            section = nextSection(after: section, rng: &rng)
        }
        return result
    }

    /// A moving, cue-aware forward window for the compact form strip.
    public func preview(startBar: Int, count: Int, sectionBars: Int,
                        cues: [ArrangementCue] = []) -> [ArrangementPreviewBar] {
        guard count > 0 else { return [] }
        return (startBar..<(startBar + count)).map { bar in
            let state = state(bar: bar, sectionBars: sectionBars, cues: cues)
            let cue = cues.first { $0.startBar == bar }?.kind
            let voices = Voice.allCases.filter { state.active[$0] ?? false }
            return ArrangementPreviewBar(bar: bar, section: state.section,
                                         tension: state.tension,
                                         activeVoices: voices,
                                         event: state.event, cue: cue)
        }
    }

    /// Continuous kit presence 0…1 — a deterministic bounded-lookback slew
    /// of a tension-driven target, so drums blend in over ~3 bars and out
    /// over ~4–5 instead of switching. A pre-drop `.vacuum` cuts to zero;
    /// the `.drop` itself lands at full presence.
    /// The tension floor each voice needs before its activity gate can open.
    /// Exposed so the per-voice `amount` knob can bias against it.
    public static func activityThreshold(for voice: Voice) -> Double {
        switch voice {
        case .drone:  return 0.0
        case .melody: return 0.02
        case .chords: return 0.10
        case .drums:  return 0.15
        case .bass:   return 0.35
        case .pulse:  return 0.26
        }
    }

    /// `tensionBias` shifts the presence *target* (the drums `amount` knob):
    /// positive invites the kit in at lower tension, negative holds it back.
    /// `presenceFloor` is the knob's stronger promise: a minimum presence the
    /// kit never drops below (halved when a section's seeded draw rests the
    /// kit; drop/exhale bars still cut to 0).
    public func drumPresence(bar: Int, sectionBars: Int, tensionBias: Double = 0,
                             presenceFloor: Double = 0,
                             cues: [ArrangementCue] = []) -> Double {
        let attackPerBar = 0.34         // silence → full kit in ~3 bars
        let releasePerBar = 0.22        // full → silence in ~4–5 bars
        func target(_ st: ConductorState) -> Double {
            let t = st.tension
            // active[.drums] == false above the 0.15 gate threshold means the
            // section's seeded draw rested the kit (the sit-out check stays
            // on unbiased tension); the user's floor still whispers through
            // a rest at half strength.
            let sitsOut = t >= 0.15 && !(st.active[.drums] ?? false)
            let base = sitsOut ? 0 : smoothstep01((t + tensionBias - 0.24) / 0.45)
            let normal = max(base, sitsOut ? presenceFloor * 0.5 : presenceFloor)
            switch st.event {
            case .build:   return max(0.78, normal)
            case .drop:    return 1
            case .vacuum:  return 0
            case .exhale:  return 0
            case nil:      return normal
            }
        }

        // Fold from far enough back that the slew has converged; the value
        // is independent of the window start in practice, and deterministic
        // always.
        var p = 0.0
        for b in max(0, bar - 10)...bar {
            let st = state(bar: b, sectionBars: sectionBars, cues: cues)
            if st.event == .vacuum {
                p = 0
                continue
            }
            if st.event == .drop {
                p = 1
                continue
            }
            p += min(max(target(st) - p, -releasePerBar), attackPerBar)
            p = min(1, max(0, p))
        }
        return p
    }

    /// Effective schedule after deterministic, persisted live cues.
    public func state(bar: Int, sectionBars: Int,
                      cues: [ArrangementCue] = []) -> ConductorState {
        let ordered = cues.sorted { ($0.startBar, $0.kind.rawValue) < ($1.startBar, $1.kind.rawValue) }
        var offset = 0
        var forcedDrop = false

        for cue in ordered where cue.startBar <= bar {
            let mappedStart = cue.startBar + offset
            switch cue.kind {
            case .buildDrop:
                if bar < cue.startBar + 3 {
                    let phase = bar - cue.startBar
                    let event: SectionEvent = phase < 2 ? .build : .vacuum
                    let tension = phase == 0 ? 0.72 : (phase == 1 ? 0.84 : 0.96)
                    let underlying = baseState(bar: mappedStart, sectionBars: sectionBars)
                    var active = underlying.active
                    if event == .vacuum {
                        for voice in Voice.allCases {
                            active[voice] = voice == .drone || voice == .melody
                        }
                    } else {
                        active[.drums] = true
                        active[.melody] = true
                        active[.pulse] = true
                    }
                    return ConductorState(section: .develop, sectionBar: phase + 1,
                                          sectionLength: 4, tension: tension,
                                          active: active, focus: .pulse,
                                          event: event, horizon: underlying.horizon)
                }
                let landingReal = cue.startBar + 3
                let mappedLanding = landingReal + offset
                let target = nextStart(of: .peak, atOrAfter: mappedLanding,
                                       sectionBars: sectionBars)
                offset += target - mappedLanding
                if bar == landingReal { forcedDrop = true }

            case .breakdown:
                let target = nextStart(of: .breakdown, atOrAfter: mappedStart,
                                       sectionBars: sectionBars)
                offset += target - mappedStart

            case .nextSection:
                let here = baseState(bar: mappedStart, sectionBars: sectionBars)
                offset += here.sectionLength - here.sectionBar
            }
        }

        let base = baseState(bar: bar + offset, sectionBars: sectionBars)
        guard forcedDrop else { return base }
        var active = base.active
        for voice in Voice.allCases { active[voice] = true }
        return ConductorState(section: .peak, sectionBar: 0,
                              sectionLength: base.sectionLength,
                              tension: max(0.94, base.tension), active: active,
                              focus: base.focus, event: .drop, horizon: base.horizon)
    }

    private func nextStart(of target: Section, atOrAfter bar: Int,
                           sectionBars: Int) -> Int {
        var probe = max(0, bar)
        for _ in 0..<1024 {
            let state = baseState(bar: probe, sectionBars: sectionBars)
            if state.section == target, state.sectionBar == 0 { return probe }
            probe += max(1, state.sectionLength - state.sectionBar)
        }
        return bar
    }

    private func baseState(bar: Int, sectionBars: Int) -> ConductorState {
        let sched = schedule(upTo: bar, sectionBars: sectionBars)
        var start = 0
        var idx = 0
        for (i, (_, len)) in sched.enumerated() {
            if bar < start + len { idx = i; break }
            start += len
            idx = i
        }
        let (section, len) = sched[idx]
        let into = bar - start
        let previousSection: Section? = idx > 0 ? sched[idx - 1].0 : nil
        let nextSection: Section? = idx + 1 < sched.count ? sched[idx + 1].0 : nil

        // One decision belongs to the target peak and is recomputed from the
        // same seed in both the preceding develop and the peak itself.
        let targetPeakIndex = section == .peak ? idx : idx + 1
        var peakPlanRNG = RNG(seed: hashSeed(seed, 0x4556_4E54,
                                            UInt64(max(0, targetPeakIndex))))
        let hasDropPlan = peakPlanRNG.chance(0.85)
        var event: SectionEvent? = nil
        if section == .develop, nextSection == .peak, hasDropPlan {
            if into == len - 1 { event = .vacuum }
            else if into >= len - 3 { event = .build }
        } else if section == .peak, into == 0, previousSection == .develop, hasDropPlan {
            event = .drop
        } else if section == .breakdown, into < 2, previousSection == .peak {
            event = .exhale
        }

        let phase = Double(into) / Double(max(1, len - 1))
        let (t0, t1) = section.tensionRamp
        // Ramp plus a slow deterministic wiggle so tension isn't a straight line.
        let wiggle = ValueNoise(seed: hashSeed(seed, 0x5457)).value(Double(bar) / 6.0) * 0.06
        var tension = min(1, max(0, t0 + (t1 - t0) * phase + wiggle))
        switch event {
        case .build:
            let buildStep = into - (len - 3)
            tension = max(tension, 0.72 + Double(buildStep) * 0.12)
        case .vacuum: tension = max(tension, 0.96)
        case .drop:   tension = max(tension, 0.94)
        case .exhale: tension = min(tension, into == 0 ? 0.42 : 0.28)
        case nil: break
        }

        // Activity gates: which voices play. Seeded per section so entries
        // and exits are decisive, not flickering. Ambient ordering: the drone
        // is always on, melody (the loop layer) enters almost immediately,
        // the kit and bass are late arrivals.
        var gateRNG = RNG(seed: hashSeed(seed, 0x47415445, UInt64(idx)))
        var active: [Voice: Bool] = [:]
        // Section-level eligibility (ramp midpoint, ignoring the per-bar
        // wiggle) so the focus choice below never flickers within a section.
        var eligible: [Voice: Bool] = [:]
        let midTension = (t0 + t1) / 2
        for voice in Voice.allCases {
            let threshold = Self.activityThreshold(for: voice)
            let restProb: Double
            switch voice {
            case .drone:  restProb = 0
            case .melody: restProb = 0.10
            case .chords: restProb = 0.18
            case .drums:  restProb = 0.12
            case .bass:   restProb = 0.06
            case .pulse:  restProb = 0.12
            }
            // A voice may sit out a section even above threshold — space is
            // arrangement.
            let sitsOut = gateRNG.chance(restProb) && section != .peak
            active[voice] = tension >= threshold && !sitsOut
            eligible[voice] = midTension >= threshold && !sitsOut
        }
        // Intro: the drone opens the piece.
        if section == .intro { active[.drone] = true }
        eligible[.drone] = true

        // Boundary orchestration is explicit. The vacuum retains only a
        // thread to pull into the landing; the drop itself is collective.
        switch event {
        case .vacuum:
            for voice in Voice.allCases { active[voice] = voice == .drone || voice == .melody }
        case .drop:
            for voice in Voice.allCases { active[voice] = true }
        case .build:
            active[.drums] = true
            active[.melody] = true
            active[.pulse] = true
        case .exhale, nil:
            break
        }

        // Focus voice: one foreground element per section, seeded so it is
        // stable for the section's whole span.
        var focusRNG = RNG(seed: hashSeed(seed, 0x464F_4355, UInt64(idx)))
        let order: [Voice] = [.drums, .bass, .chords, .melody, .drone, .pulse]
        let focusWeights: [Double]
        switch section {
        case .intro:     focusWeights = [0, 0, 1.0, 1.2, 0, 0.2]
        case .develop:   focusWeights = [0, 1.0, 0.8, 1.0, 0, 1.2]
        case .peak:      focusWeights = [1.0, 1.0, 0, 0.8, 0, 1.1]
        case .breakdown: focusWeights = [0, 0, 1.0, 0.8, 0, 0.35]
        }
        var focus = order[focusRNG.pick(focusWeights)]
        if !(eligible[focus] ?? false) {
            focus = [.chords, .melody, .drone].first { eligible[$0] ?? false } ?? .drone
        }

        var horizon: [(Section, Int)] = []
        for i in idx..<min(idx + 4, sched.count) { horizon.append(sched[i]) }
        return ConductorState(section: section, sectionBar: into, sectionLength: len,
                              tension: tension, active: active, focus: focus,
                              event: event, horizon: horizon)
    }
}
