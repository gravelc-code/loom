import Foundation

/// The classic-progression bank: proven phrases with real cadences, the
/// backbone the wander knob departs from. Phrases are degree sequences with
/// per-step durations, so harmonic rhythm is baked in and chord changes only
/// ever land on bar boundaries.

/// How a step's chord is colored beyond the plain diatonic triad.
public enum QualityHint: Sendable, Equatable {
    /// Diatonic triad; tension may probabilistically add 7th/9th/sus color.
    case diatonic
    /// Force a dominant 7th (major third + minor 7th) — the classic V7 even
    /// in minor, where the raised third is the harmonic-minor leading tone.
    case dominant7
    /// Force a minor 7th chord.
    case minor7
    /// Suspended 4th.
    case sus4
}

/// What the end of the phrase does — used for phrase chaining and so the
/// voices can lean into the resolution.
public enum Cadence: String, Sendable {
    case authentic   // ends V(7) → next phrase wants to open on the tonic
    case half        // ends on V — open, wants to continue
    case plagal      // ends IV → tonic
    case deceptive   // resolves somewhere unexpected
    case none        // vamp/pedal, no cadence
}

public enum ModeFamily: Sendable, Equatable { case major, minor }

/// A piece-level harmonic identity. Individual phrases may cross stylistic
/// borders, but a seed no longer wanders indiscriminately from glacial modal
/// ambience into blues or gospel grammar and back.
public enum HarmonicDialect: String, CaseIterable, Codable, Sendable {
    case ambient, cinematic, soul
}

extension Scale {
    public var modeFamily: ModeFamily {
        switch self {
        case .major, .mixolydian, .lydian: return .major
        case .minor, .dorian, .phrygian:   return .minor
        }
    }
}

public struct ProgressionStep: Sendable {
    /// 0-based diatonic degree of the chord root (0 = tonic). Retained for
    /// timing/legend even when `applied` makes the sounding chord chromatic.
    public let degree: Int
    /// Bars this chord holds.
    public let bars: Int
    public let quality: QualityHint
    /// When set, this step is a *secondary dominant* resolving to the diatonic
    /// degree `applied`: its root is a fifth above that degree's root, giving a
    /// chromatic V7/x that pulls into the next chord. Off-scale tones live in
    /// the lattice (like any V7's leading tone), not the diatonic scale mask.
    public let applied: Int?

    public init(_ degree: Int, _ bars: Int = 1, _ quality: QualityHint = .diatonic,
                applied: Int? = nil) {
        self.degree = degree
        self.bars = bars
        self.quality = quality
        self.applied = applied
    }
}

public struct ProgressionPhrase: Sendable {
    public let name: String
    public let steps: [ProgressionStep]
    public let modeFamily: ModeFamily
    public let cadence: Cadence
    /// Conductor-tension band where this phrase is eligible.
    public let energy: ClosedRange<Double>
    public let weight: Double

    public var bars: Int { steps.reduce(0) { $0 + $1.bars } }
}

public enum ProgressionBank {
    public static let phrases: [ProgressionPhrase] = [
        // — ambient minor (glacial harmonic rhythm; the low-tension bed) —
        ProgressionPhrase(name: "abyss", steps: [.init(0, 8)],
                          modeFamily: .minor, cadence: .none, energy: 0.0...0.55, weight: 1.2),
        ProgressionPhrase(name: "drift", steps: [.init(0, 4), .init(5, 4)],
                          modeFamily: .minor, cadence: .none, energy: 0.0...0.55, weight: 1.0),
        ProgressionPhrase(name: "undertow", steps: [.init(0, 4), .init(3, 4)],
                          modeFamily: .minor, cadence: .plagal, energy: 0.0...0.55, weight: 1.0),
        ProgressionPhrase(name: "veil", steps: [.init(0, 8), .init(6, 4), .init(0, 4)],
                          modeFamily: .minor, cadence: .none, energy: 0.0...0.55, weight: 0.9),
        ProgressionPhrase(name: "descent", steps: [.init(0, 4), .init(5, 4), .init(3, 4), .init(0, 4)],
                          modeFamily: .minor, cadence: .plagal, energy: 0.0...0.55, weight: 0.9),

        // — ambient major mirrors —
        ProgressionPhrase(name: "aurora", steps: [.init(0, 8)],
                          modeFamily: .major, cadence: .none, energy: 0.0...0.55, weight: 1.2),
        ProgressionPhrase(name: "expanse", steps: [.init(0, 4), .init(3, 4)],
                          modeFamily: .major, cadence: .plagal, energy: 0.0...0.55, weight: 1.0),
        ProgressionPhrase(name: "slowturn", steps: [.init(0, 8), .init(5, 4), .init(0, 4)],
                          modeFamily: .major, cadence: .none, energy: 0.0...0.55, weight: 0.9),

        // — minor —
        ProgressionPhrase(name: "pedal", steps: [.init(0, 4)],
                          modeFamily: .minor, cadence: .none, energy: 0.0...0.4, weight: 0.7),
        ProgressionPhrase(name: "axis", steps: [.init(0), .init(5), .init(2), .init(6)],
                          modeFamily: .minor, cadence: .half, energy: 0.35...0.85, weight: 1.0),
        ProgressionPhrase(name: "andalusian", steps: [.init(0), .init(6), .init(5), .init(4, 1, .dominant7)],
                          modeFamily: .minor, cadence: .authentic, energy: 0.3...1.0, weight: 0.9),
        ProgressionPhrase(name: "lament", steps: [.init(0), .init(5), .init(3), .init(4)],
                          modeFamily: .minor, cadence: .half, energy: 0.3...0.7, weight: 0.8),
        ProgressionPhrase(name: "night drive", steps: [.init(0, 2), .init(5, 2), .init(2, 2), .init(6, 2)],
                          modeFamily: .minor, cadence: .half, energy: 0.3...1.0, weight: 0.8),
        ProgressionPhrase(name: "turn", steps: [.init(0), .init(3), .init(6), .init(2)],
                          modeFamily: .minor, cadence: .deceptive, energy: 0.2...0.8, weight: 0.7),
        ProgressionPhrase(name: "epic", steps: [.init(0, 2), .init(5), .init(6), .init(0, 2), .init(3), .init(4, 1, .dominant7)],
                          modeFamily: .minor, cadence: .authentic, energy: 0.4...1.0, weight: 0.7),
        ProgressionPhrase(name: "vamp", steps: [.init(0, 2), .init(3, 2)],
                          modeFamily: .minor, cadence: .none, energy: 0.1...0.6, weight: 0.5),

        // — major —
        ProgressionPhrase(name: "pedal", steps: [.init(0, 4)],
                          modeFamily: .major, cadence: .none, energy: 0.0...0.4, weight: 0.7),
        ProgressionPhrase(name: "axis", steps: [.init(0), .init(4), .init(5), .init(3)],
                          modeFamily: .major, cadence: .plagal, energy: 0.35...0.85, weight: 1.0),
        ProgressionPhrase(name: "pop turn", steps: [.init(5), .init(3), .init(0), .init(4)],
                          modeFamily: .major, cadence: .half, energy: 0.2...0.9, weight: 0.9),
        ProgressionPhrase(name: "doo-wop", steps: [.init(0), .init(5), .init(3), .init(4)],
                          modeFamily: .major, cadence: .half, energy: 0.35...0.8, weight: 0.9),
        ProgressionPhrase(name: "ii-V-I", steps: [.init(1, 1, .minor7), .init(4, 1, .dominant7), .init(0, 2)],
                          modeFamily: .major, cadence: .authentic, energy: 0.2...0.8, weight: 0.7),
        ProgressionPhrase(name: "gospel", steps: [.init(0, 2), .init(3), .init(4)],
                          modeFamily: .major, cadence: .half, energy: 0.3...0.7, weight: 0.6),
        ProgressionPhrase(name: "12-bar blues",
                          steps: [.init(0), .init(0), .init(0), .init(0, 1, .dominant7),
                                  .init(3), .init(3), .init(0), .init(0),
                                  .init(4, 1, .dominant7), .init(3), .init(0), .init(4, 1, .dominant7)],
                          modeFamily: .major, cadence: .half, energy: 0.35...1.0, weight: 0.5),
    ]

    /// Phrases eligible for a family at a tension, falling back to the whole
    /// family (then the whole bank) so the set is never empty.
    static func eligible(family: ModeFamily, tension: Double,
                         dialect: HarmonicDialect) -> [ProgressionPhrase] {
        let inFamily = phrases.filter { $0.modeFamily == family }
        let inDialect = inFamily.filter { supports($0, dialect: dialect) }
        let inBand = inDialect.filter { $0.energy.contains(tension) }
        if !inBand.isEmpty { return inBand }
        if !inDialect.isEmpty { return inDialect }
        if !inFamily.isEmpty { return inFamily }
        return phrases
    }

    static func supports(_ phrase: ProgressionPhrase, dialect: HarmonicDialect) -> Bool {
        let ambient: Set<String> = ["abyss", "drift", "undertow", "veil", "descent",
                                    "aurora", "expanse", "slowturn", "pedal", "vamp"]
        let cinematic: Set<String> = ["abyss", "drift", "undertow", "veil", "descent",
                                      "aurora", "expanse", "slowturn", "pedal", "axis",
                                      "andalusian", "lament", "night drive", "turn", "epic",
                                      "pop turn", "vamp"]
        let soul: Set<String> = ["pedal", "axis", "pop turn", "doo-wop", "ii-V-I",
                                 "gospel", "12-bar blues", "vamp"]
        switch dialect {
        case .ambient: return ambient.contains(phrase.name)
        case .cinematic: return cinematic.contains(phrase.name)
        case .soul: return soul.contains(phrase.name)
        }
    }

    /// Functional substitutes per degree, used by the wander knob: chords
    /// that share function (and usually two tones) with the original.
    static let substitutions: [[Int]] = [
        /* I  */ [5, 2],
        /* ii */ [3],
        /* iii*/ [5],
        /* IV */ [1, 5],
        /* V  */ [6],
        /* vi */ [3, 0],
        /* vii*/ [4],
    ]
}
