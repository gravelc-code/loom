import Foundation

/// The anti-elevator-music system.
///
/// loom's generators are, by construction, consonance-preserving and slow:
/// every structural mechanism (sections, movements, groove style) works on a
/// 40–90 bar timescale, and everything faster is ±10% parameter drift. Left
/// alone that converges on pleasant wallpaper.
///
/// This is the feedback loop that stops it. The engine listens to what it
/// just played over a rolling window, scores it on five axes, and when the
/// music has been bland for too long it *forces* a structural event on the
/// next bar. The `grit` macro raises the baseline so disruptions also happen
/// before the watchdog has to intervene.
///
/// Determinism: the analyzer is fed only by bars generated in order and is
/// reset by `Engine.rewind()`, exactly like `smoothedActivity`. It must
/// never influence harmony, drone spans or the conductor — those are
/// recomputed for arbitrary bars and must stay pure functions of the seed.
public struct InterestMetrics: Sendable, Equatable {
    /// Are the notes themselves varied — pitch classes, intervals, and how
    /// unlike its predecessor each bar is?
    public var variety: Double = 0.5
    /// Is there a real dynamic range, or is everything at one comfortable
    /// level?
    public var dynamics: Double = 0.5
    /// Is there genuine silence — holes, not just gaps between notes?
    public var space: Double = 0.5
    /// Is the harmony moving, and does it have any bite?
    public var harmony: Double = 0.5
    /// How long since anything structurally surprising happened?
    public var surprise: Double = 0.5

    public init() {}

    /// The headline score. Variety and surprise carry the most weight —
    /// they're what "elevator music" most lacks.
    public var overall: Double {
        variety * 0.3 + dynamics * 0.15 + space * 0.15 + harmony * 0.2 + surprise * 0.2
    }

    public var worst: String {
        let pairs = [("variety", variety), ("dynamics", dynamics), ("space", space),
                     ("harmony", harmony), ("surprise", surprise)]
        return pairs.min { $0.1 < $1.1 }?.0 ?? "variety"
    }
}

/// A structural intervention applied to a single bar (or a short run).
public enum Disruption: String, Sendable, CaseIterable {
    /// Real space: everything but the drone drops out.
    case silence
    /// One voice alone, naked.
    case solo
    /// The kit stutters while the pitched voices vanish.
    case stutter
    /// Sudden quiet — the whole bar pulls back.
    case hush
    /// Sudden force — the whole bar leans in.
    case swell
    /// Melody jumps an octave up, bass an octave down.
    case registerLeap
    /// Chromatic tones, rubs and borrowed color are permitted this bar.
    case harmonicBite
    /// The downbeat moves, or the shared skeleton dissolves.
    case meterBreak

    public var label: String { rawValue }
}

/// Rolling-window analysis of what the engine actually played.
public final class InterestAnalyzer {
    /// How many bars of history the metrics consider.
    public static let window = 16
    /// How many consecutive bland bars before the watchdog forces an event.
    static let patience = 3

    struct BarRecord {
        let pitchClasses: [Int]
        let onsets: Set<Int>          // 16th-grid positions, pitched + drums
        let velocities: [Int]
        let chordRoot: Int
        let poolKey: Int
        let chromaticCount: Int
        let noteCount: Int
    }

    private var history: [BarRecord] = []
    private var blandRun = 0
    private var barsSinceEvent = 99
    /// The disruption chosen for the *next* bar, if any.
    public private(set) var pending: Disruption?
    /// A disruption the user asked for from the UI (honoured next bar).
    public var userRequested = false
    private var requestedKind: Disruption?
    public private(set) var metrics = InterestMetrics()
    /// What actually fired on the bar just generated (for the UI).
    public private(set) var lastApplied: Disruption?

    public init() {}

    /// Full watchdog state, for the display lookahead's snapshot/restore. The
    /// analyzer is sequential and can *force* a disruption on the next bar, so a
    /// preview must restore it or real playback's disruption timing would drift.
    struct State {
        var history: [BarRecord]; var blandRun: Int; var barsSinceEvent: Int
        var pending: Disruption?; var userRequested: Bool; var requestedKind: Disruption?
        var metrics: InterestMetrics; var lastApplied: Disruption?
    }
    func captureState() -> State {
        State(history: history, blandRun: blandRun, barsSinceEvent: barsSinceEvent,
              pending: pending, userRequested: userRequested, requestedKind: requestedKind,
              metrics: metrics, lastApplied: lastApplied)
    }
    func restore(_ s: State) {
        history = s.history; blandRun = s.blandRun; barsSinceEvent = s.barsSinceEvent
        pending = s.pending; userRequested = s.userRequested; requestedKind = s.requestedKind
        metrics = s.metrics; lastApplied = s.lastApplied
    }

    public func reset() {
        history.removeAll()
        blandRun = 0
        barsSinceEvent = 99
        pending = nil
        userRequested = false
        requestedKind = nil
        metrics = InterestMetrics()
        lastApplied = nil
    }

    /// Take the disruption scheduled for this bar (clears it).
    public func takePending() -> Disruption? {
        let d = pending
        pending = nil
        lastApplied = d
        if d != nil { barsSinceEvent = 0 }
        return d
    }

    /// Ask for either a particular intervention or a context-sensitive one.
    /// It is scheduled by `observe`, so conductor events still retain priority.
    public func request(_ kind: Disruption? = nil) {
        if let kind { requestedKind = kind } else { userRequested = true }
    }

    /// Record a generated bar and decide whether the next one needs help.
    /// `hadSectionEvent` covers the conductor's own drop/exhale so the
    /// watchdog doesn't pile on top of them.
    public func observe(bar: Int, events: [NoteEvent], chordRoot: Int, pool: [Int],
                        latticeMask: UInt16, hadSectionEvent: Bool,
                        grit: Double, seed: UInt64) {
        let pitched = events.filter { $0.voice != .drums }
        var chromatic = 0
        for e in pitched where latticeMask & (1 << UInt16(((e.note % 12) + 12) % 12)) == 0 {
            chromatic += 1
        }
        let record = BarRecord(
            pitchClasses: pitched.map { ((($0.note % 12) + 12) % 12) },
            onsets: Set(events.map { Int($0.startStep.rounded(.down)) }),
            velocities: events.map(\.velocity),
            chordRoot: chordRoot,
            poolKey: pool.reduce(0) { $0 &* 13 &+ $1 },
            chromaticCount: chromatic,
            noteCount: events.count)
        history.append(record)
        if history.count > Self.window { history.removeFirst(history.count - Self.window) }

        barsSinceEvent = hadSectionEvent ? 0 : barsSinceEvent + 1
        metrics = compute()

        // The watchdog. A low score for several bars in a row means the
        // music has settled into wallpaper — intervene on the next bar.
        let threshold = 0.40 + grit * 0.16
        if metrics.overall < threshold { blandRun += 1 } else { blandRun = 0 }

        // At grit zero the original strictly-consonant engine is preserved.
        // The analyzer still measures the music for the UI, but only an
        // explicit user request may intervene. This also gives hosts a true
        // "no surprises" setting.
        var fire = grit > 0 && blandRun >= Self.patience
        // Grit also fires disruptions on its own, before things get bland.
        if !fire && grit > 0 && barsSinceEvent >= 4 {
            var rng = RNG(seed: hashSeed(seed, 0x4752_4954, UInt64(max(0, bar))))
            fire = rng.chance(0.03 + grit * 0.15)
        }
        if userRequested || requestedKind != nil { fire = true; userRequested = false }

        if fire && !hadSectionEvent {
            pending = requestedKind ?? choose(bar: bar, seed: seed, grit: grit)
            requestedKind = nil
            blandRun = 0
        }
    }

    /// Pick a disruption that addresses whichever axis is weakest — bland
    /// harmony summons bite, a wall of sound summons silence, flat
    /// dynamics summons a swell.
    private func choose(bar: Int, seed: UInt64, grit: Double) -> Disruption {
        var rng = RNG(seed: hashSeed(seed, 0x4449_5352, UInt64(max(0, bar))))
        var weights: [Disruption: Double] = [
            .silence: 1, .solo: 1, .stutter: 0.6, .hush: 0.8, .swell: 0.8,
            .registerLeap: 0.9, .harmonicBite: 1, .meterBreak: 0.8,
        ]
        switch metrics.worst {
        case "space":    weights[.silence] = 4; weights[.solo] = 2.5; weights[.hush] = 2
        case "dynamics": weights[.swell] = 3.5; weights[.hush] = 3
        case "harmony":  weights[.harmonicBite] = 4.5; weights[.registerLeap] = 1.6
        case "variety":  weights[.meterBreak] = 3; weights[.registerLeap] = 2.5
                         weights[.harmonicBite] = 2; weights[.stutter] = 1.6
        default:         weights[.silence] = 2; weights[.meterBreak] = 2
        }
        // Harmonic bite is only musical if there's grit to resolve it with.
        if grit < 0.15 { weights[.harmonicBite] = 0.2 }
        let order = Disruption.allCases
        return order[rng.pick(order.map { weights[$0] ?? 1 })]
    }

    private func compute() -> InterestMetrics {
        var m = InterestMetrics()
        guard history.count >= 2 else { return m }

        // Variety: pitch-class entropy across the window, plus how unlike
        // each bar is from the one before it (a loop scores badly).
        var pcCounts = [Double](repeating: 0, count: 12)
        var total = 0.0
        for rec in history {
            for pc in rec.pitchClasses { pcCounts[pc] += 1; total += 1 }
        }
        var entropy = 0.0
        if total > 0 {
            for c in pcCounts where c > 0 {
                let p = c / total
                entropy -= p * log2(p)
            }
            entropy /= log2(12)   // 0…1
        }
        var novelty = 0.0
        for i in 1..<history.count {
            let a = history[i - 1].onsets, b = history[i].onsets
            let union = a.union(b).count
            novelty += union == 0 ? 0 : 1 - Double(a.intersection(b).count) / Double(union)
        }
        novelty /= Double(history.count - 1)
        m.variety = min(1, entropy * 0.55 + novelty * 0.75)

        // Dynamics: the spread between quiet and loud, not the average.
        let vels = history.flatMap(\.velocities).sorted()
        if vels.count >= 4 {
            let lo = Double(vels[Int(Double(vels.count) * 0.1)])
            let hi = Double(vels[min(vels.count - 1, Int(Double(vels.count) * 0.9))])
            m.dynamics = min(1, (hi - lo) / 55.0)
        } else {
            m.dynamics = 0.3
        }

        // Space: real holes. Both the fraction of empty 16ths and the
        // longest unbroken silence count — a wall of quiet notes is not
        // space, and neither is an even scatter.
        let occupancy = history.map { Double($0.onsets.count) / 16.0 }
        let emptiness = 1 - min(1, occupancy.reduce(0, +) / Double(occupancy.count))
        var longestQuiet = 0, run = 0
        for rec in history {
            if rec.noteCount <= 2 { run += 1; longestQuiet = max(longestQuiet, run) } else { run = 0 }
        }
        m.space = min(1, emptiness * 0.8 + min(1, Double(longestQuiet) / 3.0) * 0.4)

        // Harmony: is it moving, and does it have any bite?
        var rootChanges = 0.0, poolChanges = 0.0
        for i in 1..<history.count {
            if history[i].chordRoot != history[i - 1].chordRoot { rootChanges += 1 }
            if history[i].poolKey != history[i - 1].poolKey { poolChanges += 1 }
        }
        let span = Double(history.count - 1)
        let chroma = min(1, Double(history.reduce(0) { $0 + $1.chromaticCount }) / max(1, total) * 6)
        m.harmony = min(1, (rootChanges / span) * 1.6 + (poolChanges / span) * 0.6 + chroma * 0.5)

        // Surprise: decays the longer nothing structural has happened.
        m.surprise = max(0, 1 - Double(barsSinceEvent) / 12.0)
        return m
    }
}
