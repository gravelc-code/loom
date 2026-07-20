import Foundation

/// Documented, real-world drum grooves — not a per-step probability cloud. Each
/// pattern separates a **fixed core** (the kick + snare hits that *are* the
/// groove's identity, never re-rolled) from **authored optional layers** (ghost
/// snares, hat subdivisions, open hats, perc). The generator peels those layers
/// with the arrangement (presence / section) and scales them with the density
/// sliders, so the identity is untouchable while the variation stays idiomatic
/// and slider-controlled. Sources: boom-bap/trip-hop backbeat + swung hats, the
/// Amen break (kick 1 + 16th kicks, displaced snare, 16th ghosts), jungle
/// "chikka-chikka" (offbeat hat + following-16th ghost snare), IDM off-grid
/// ghost notes floating over pads.
public enum DrumGenre: String, CaseIterable, Codable, Hashable, Sendable {
    case ambient, tripHop, jungle, idm

    /// Evocative kit-character names shown to the user. The internal cases stay
    /// the documented genres they're grounded in (ambient / trip-hop / jungle /
    /// IDM); the labels are the loom-flavoured aliases.
    public var label: String {
        switch self {
        case .ambient: return "Haze"     // sparse, floating, spacious
        case .tripHop: return "Noir"     // dark, dusty, swung half-time
        case .jungle:  return "Snarl"    // fast, chopped, tangled breaks
        case .idm:     return "Rupture"  // broken, glitchy, off-grid
        }
    }

    /// Half-time genres push the swing and place the phrase flam on beat 3.
    public var isHalftime: Bool { self == .ambient || self == .tripHop }

    /// The discrete drums `genre` control: 0 = auto, then the four genres at
    /// evenly spaced canonical points.
    public static func fromControl(_ v: Double) -> DrumGenre? {
        switch v {
        case ..<0.1:  return nil          // auto — seed/dialect chooses
        case ..<0.3:  return .ambient
        case ..<0.5:  return .tripHop
        case ..<0.7:  return .jungle
        default:      return .idm
        }
    }
    public var control: Double {
        switch self {
        case .ambient: return 0.2
        case .tripHop: return 0.4
        case .jungle:  return 0.6
        case .idm:     return 0.8
        }
    }

    /// Auto selection: loom's core leans sparse & supportive, so ambient/trip-hop
    /// dominate. Jungle only surfaces on the busier dialects and stays rare.
    public static func auto(dialect: HarmonicDialect, seed: UInt64) -> DrumGenre {
        var rng = RNG(seed: hashSeed(seed, 0x4752_4E52)) // "GRNR"
        switch dialect {
        case .ambient:
            return [.ambient, .tripHop, .idm][rng.pick([0.56, 0.32, 0.12])]
        case .cinematic:
            return [.tripHop, .idm, .ambient, .jungle][rng.pick([0.40, 0.28, 0.20, 0.12])]
        case .soul:
            return [.tripHop, .jungle, .idm][rng.pick([0.58, 0.24, 0.18])]
        }
    }

    /// Resolve the effective genre: an explicit control wins; then a legacy
    /// groove-style override maps to its nearest genre; otherwise auto.
    public static func resolve(control: Double, dialect: HarmonicDialect, seed: UInt64,
                               legacy: DrumGenerator.GrooveStyle?) -> DrumGenre {
        if let g = fromControl(control) { return g }
        if let legacy {
            switch legacy {
            case .halftime: return .tripHop
            case .broken:   return .idm
            case .straight: return .tripHop
            }
        }
        return auto(dialect: dialect, seed: seed)
    }
}

/// One authored hit. `tier` is used only by hats: 0 = quarter (the floor),
/// 1 = eighth, 2 = sixteenth — so a density slider peels sixteenths before
/// eighths before the quarter pulse.
public struct DrumHit: Sendable {
    public let step: Double
    public let track: DrumTrack
    public let vel: Int
    public let tier: Int
    public init(_ step: Double, _ track: DrumTrack, _ vel: Int, tier: Int = 0) {
        self.step = step; self.track = track; self.vel = vel; self.tier = tier
    }
}

/// A single documented groove. Optional-layer arrays are ordered **most
/// important first** so the generator can keep the top-K under a low slider.
public struct DrumPattern: Sendable {
    public let genre: DrumGenre
    public let core: [DrumHit]      // kick + snare identity — never re-rolled
    public let ghosts: [DrumHit]    // ghost snares (quiet)
    public let hats: [DrumHit]      // closed hats, quarter → eighth → sixteenth
    public let openHats: [DrumHit]  // open hats (choke the closed hat they share a step with)
    public let perc: [DrumHit]      // rim / perc figures (core-kit pads only)
    public let swingsHats: Bool
}

public enum DrumPatternLibrary {

    /// closed-hat helper: quarters (tier 0), eighths (tier 1), sixteenths (tier 2).
    static func hats(q: [Int] = [], e: [Int] = [], s: [Int] = [],
                     vq: Int = 60, ve: Int = 50, vs: Int = 40) -> [DrumHit] {
        q.map { DrumHit(Double($0), .hat, vq, tier: 0) }
        + e.map { DrumHit(Double($0), .hat, ve, tier: 1) }
        + s.map { DrumHit(Double($0), .hat, vs, tier: 2) }
    }

    /// The whole authored library. Seed picks a sibling within the chosen genre.
    public static let all: [DrumGenre: [DrumPattern]] = [
        .ambient: ambient,
        .tripHop: tripHop,
        .jungle:  jungle,
        .idm:     idm,
    ]

    public static func pattern(genre: DrumGenre, seed: UInt64) -> DrumPattern {
        let bank = all[genre] ?? tripHop
        var rng = RNG(seed: hashSeed(seed, 0x5054_524E)) // "PTRN"
        return bank[rng.int(bank.count)]
    }

    // MARK: Ambient — sparsest. Kick pulse, brushed offbeat hat, snare mostly absent.
    static let ambient: [DrumPattern] = [
        // Heartbeat: soft kick on 1 & 3, a lone brushed offbeat hat, rim landmark.
        DrumPattern(genre: .ambient,
                    core: [DrumHit(0, .kick, 70), DrumHit(8, .kick, 58)],
                    ghosts: [],
                    hats: hats(q: [4, 12], e: [2, 6, 10, 14], vq: 34, ve: 28),
                    openHats: [],
                    perc: [DrumHit(14, .rim, 32), DrumHit(6, .rim, 26)],
                    swingsHats: true),
        // Single pulse: kick on 1, gentle eighth pulse hats, cross-stick backbeat.
        DrumPattern(genre: .ambient,
                    core: [DrumHit(0, .kick, 66), DrumHit(6, .kick, 48)],
                    ghosts: [],
                    hats: hats(q: [0, 4, 8, 12], e: [2, 6, 10, 14], vq: 32, ve: 26),
                    openHats: [],
                    perc: [DrumHit(8, .rim, 44), DrumHit(12, .rim, 30)],
                    swingsHats: true),
        // Dub-slow: kick 1 & the "and" of 2, wide cross-stick on 3, sparse hats.
        DrumPattern(genre: .ambient,
                    core: [DrumHit(0, .kick, 68), DrumHit(11, .kick, 46)],
                    ghosts: [],
                    hats: hats(q: [4, 12], e: [8], vq: 32, ve: 26),
                    openHats: [DrumHit(14, .hatOpen, 40)],
                    perc: [DrumHit(8, .rim, 46)],
                    swingsHats: true),
    ]

    // MARK: Trip-hop / boom-bap — swung backbeat with quiet ghost snares.
    static let tripHop: [DrumPattern] = [
        // Half-time: kick 1 (+ syncopated 16th), snare on beat 3, ghost on the "a".
        DrumPattern(genre: .tripHop,
                    core: [DrumHit(0, .kick, 100), DrumHit(10, .kick, 72), DrumHit(8, .snare, 98)],
                    ghosts: [DrumHit(11, .snare, 34), DrumHit(6, .snare, 28), DrumHit(15, .snare, 30)],
                    hats: hats(q: [0, 4, 8, 12], e: [2, 6, 10, 14], s: [3, 11],
                               vq: 64, ve: 54, vs: 42),
                    openHats: [DrumHit(14, .hatOpen, 70)],
                    perc: [DrumHit(6, .rim, 40), DrumHit(2, .perc, 30)],
                    swingsHats: true),
        // Boom-bap: kick 1 & 3 (+ "and-a" of 3), snare 2 & 4, ghost snares, swung.
        DrumPattern(genre: .tripHop,
                    core: [DrumHit(0, .kick, 100), DrumHit(8, .kick, 90), DrumHit(11, .kick, 66),
                           DrumHit(4, .snare, 98), DrumHit(12, .snare, 98)],
                    ghosts: [DrumHit(7, .snare, 32), DrumHit(15, .snare, 34), DrumHit(10, .snare, 28)],
                    hats: hats(q: [0, 4, 8, 12], e: [2, 6, 10, 14], s: [3, 7, 11, 15],
                               vq: 62, ve: 52, vs: 40),
                    openHats: [DrumHit(10, .hatOpen, 66)],
                    perc: [DrumHit(6, .rim, 38)],
                    swingsHats: true),
        // Dusty: kick 1 & the "and" of 2, snare 2 & 4, laid-back ghosts.
        DrumPattern(genre: .tripHop,
                    core: [DrumHit(0, .kick, 98), DrumHit(7, .kick, 64),
                           DrumHit(4, .snare, 96), DrumHit(12, .snare, 96)],
                    ghosts: [DrumHit(10, .snare, 30), DrumHit(15, .snare, 32), DrumHit(3, .snare, 26)],
                    hats: hats(q: [0, 4, 8, 12], e: [2, 6, 10, 14], vq: 60, ve: 50),
                    openHats: [DrumHit(14, .hatOpen, 64)],
                    perc: [DrumHit(2, .perc, 30), DrumHit(10, .rim, 34)],
                    swingsHats: true),
    ]

    // MARK: Jungle — Amen-derived breaks. Energetic; reserved for peaks / explicit.
    static let jungle: [DrumPattern] = [
        // Amen (one-bar reduction): kick 1 + 16th "1-a", snare 2 & displaced 4,
        // 16th ghost snares, straight 8th hats.
        DrumPattern(genre: .jungle,
                    core: [DrumHit(0, .kick, 104), DrumHit(3, .kick, 74), DrumHit(10, .kick, 78),
                           DrumHit(4, .snare, 100), DrumHit(14, .snare, 96)],
                    ghosts: [DrumHit(7, .snare, 56), DrumHit(11, .snare, 44),
                             DrumHit(2, .snare, 34), DrumHit(15, .snare, 38)],
                    hats: hats(q: [0, 4, 8, 12], e: [2, 6, 10, 14], vq: 58, ve: 48),
                    openHats: [DrumHit(6, .hatOpen, 62)],
                    perc: [DrumHit(11, .perc, 34)],
                    swingsHats: false),
        // Chikka-chikka: offbeat closed hat + a ghost snare on the following 16th.
        DrumPattern(genre: .jungle,
                    core: [DrumHit(0, .kick, 102), DrumHit(8, .kick, 88),
                           DrumHit(4, .snare, 98), DrumHit(12, .snare, 98)],
                    ghosts: [DrumHit(3, .snare, 30), DrumHit(7, .snare, 30),
                             DrumHit(11, .snare, 30), DrumHit(15, .snare, 30)],
                    hats: hats(q: [0, 8], e: [2, 6, 10, 14], vq: 58, ve: 52),
                    openHats: [DrumHit(14, .hatOpen, 60)],
                    perc: [DrumHit(6, .perc, 32)],
                    swingsHats: false),
        // Rolling two-step chop: syncopated kicks, backbeat, dense 16th ghosts.
        DrumPattern(genre: .jungle,
                    core: [DrumHit(0, .kick, 102), DrumHit(6, .kick, 76), DrumHit(10, .kick, 80),
                           DrumHit(4, .snare, 98), DrumHit(12, .snare, 98)],
                    ghosts: [DrumHit(2, .snare, 32), DrumHit(7, .snare, 40),
                             DrumHit(9, .snare, 30), DrumHit(14, .snare, 44), DrumHit(15, .snare, 30)],
                    hats: hats(q: [0, 4, 8, 12], e: [2, 6, 10, 14], s: [3, 11], vq: 56, ve: 46, vs: 38),
                    openHats: [DrumHit(6, .hatOpen, 58)],
                    perc: [DrumHit(11, .perc, 34)],
                    swingsHats: false),
    ]

    // MARK: IDM — broken, ghost-heavy grids that float over soft pads.
    static let idm: [DrumPattern] = [
        // Broken off-grid: displaced kicks, backbeat, many quiet ghost notes.
        DrumPattern(genre: .idm,
                    core: [DrumHit(0, .kick, 96), DrumHit(7, .kick, 70), DrumHit(11, .kick, 58),
                           DrumHit(4, .snare, 94), DrumHit(12, .snare, 94)],
                    ghosts: [DrumHit(2, .snare, 30), DrumHit(6, .snare, 34),
                             DrumHit(9, .snare, 28), DrumHit(14, .snare, 32)],
                    hats: hats(q: [0, 8], e: [2, 6, 10, 14], s: [5, 13], vq: 48, ve: 42, vs: 34),
                    openHats: [DrumHit(6, .hatOpen, 54)],
                    perc: [DrumHit(3, .glitch, 44), DrumHit(13, .glitch, 40)],
                    swingsHats: false),
        // Pitched minimal: kick 1 & 3, single backbeat, rim colour, few ghosts.
        DrumPattern(genre: .idm,
                    core: [DrumHit(0, .kick, 92), DrumHit(8, .kick, 78), DrumHit(12, .snare, 90)],
                    ghosts: [DrumHit(10, .snare, 28), DrumHit(15, .snare, 30)],
                    hats: hats(q: [0, 4, 8, 12], e: [6, 14], vq: 46, ve: 38),
                    openHats: [],
                    perc: [DrumHit(4, .rim, 50), DrumHit(7, .glitch, 38)],
                    swingsHats: false),
        // Glitch two-step: kick skips a beat, off-grid snare, shuffled ghosts.
        DrumPattern(genre: .idm,
                    core: [DrumHit(0, .kick, 98), DrumHit(6, .kick, 72), DrumHit(10, .snare, 92)],
                    ghosts: [DrumHit(3, .snare, 30), DrumHit(13, .snare, 32), DrumHit(7, .snare, 26)],
                    hats: hats(q: [0, 8], e: [2, 6, 10, 14], vq: 46, ve: 40),
                    openHats: [DrumHit(14, .hatOpen, 52)],
                    perc: [DrumHit(4, .glitch, 42), DrumHit(11, .glitch, 38)],
                    swingsHats: false),
    ]
}

/// Which layers play this bar, and how strongly. Purely a function of the kit's
/// continuous `presence` — the conductor owns the arrangement (how long the kit
/// runs, when it thins for a breakdown), and the kit simply follows it. Lowering
/// presence peels layers from the busiest end first, leaving the core kick as the
/// last thing standing before silence.
///
/// The peel order matters: the kick enters first and leaves last, then the hats,
/// then the ghost snares and perc, and only above the mid-point does the snare
/// backbone land — a long stretch of hats with no kick, or a blaring snare in a
/// quiet passage, both sound wrong, so the thresholds are staggered to prevent
/// them.
public struct DrumLayers: Sendable {
    public var open: Double        // = presence, clamped
    public var coreOn: Bool        // any kit at all this bar
    public var coreGate: Double    // kick presence / loudness
    public var snareGate: Double   // include the core snare backbone
    public var eighthGate: Double  // hats at eighth density
    public var ghostGate: Double
    public var sixteenthGate: Double
    public var openHatGate: Double
    public var percGate: Double
    /// Max hat tier eligible from the arrangement alone (0 quarter … 2 sixteenth).
    public var hatTierCap: Int

    public static func compute(presence: Double) -> DrumLayers {
        let open = min(1, max(0, presence))
        func g(_ lo: Double, _ w: Double) -> Double { smoothstep01((open - lo) / w) }
        let core = g(0.30, 0.20)
        let cap = open >= 0.55 ? 2 : (open >= 0.34 ? 1 : 0)
        return DrumLayers(open: open,
                          coreOn: core > 0.02,           // kick enters ~0.30
                          coreGate: core,
                          snareGate: g(0.50, 0.12),      // backbeat lands past the mid-point
                          eighthGate: g(0.34, 0.16),     // hats follow the kick, never precede it
                          ghostGate: g(0.46, 0.18),
                          sixteenthGate: g(0.55, 0.18),
                          openHatGate: g(0.62, 0.20),
                          percGate: g(0.44, 0.20),
                          hatTierCap: cap)
    }
}
