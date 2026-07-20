import Foundation

/// Every voice parameter is stored as a normalized 0...1 value. Continuous
/// parameters bias musical distributions; discrete parameters use canonical
/// points (off/on or thirds) and are never modulation destinations.
public struct ParamID: Hashable, Sendable, CustomStringConvertible {
    public let voice: Voice
    public let name: String
    public init(_ voice: Voice, _ name: String) {
        self.voice = voice
        self.name = name
    }
    public var description: String { "\(voice.rawValue).\(name)" }
}

/// A voice's parameter set: base values (what the user set) live here;
/// effective values (base + modulation, clamped) are computed per bar.
public struct ParamSet: Sendable {
    public var values: [String: Double]
    public let voice: Voice

    public init(voice: Voice, defaults: [String: Double]) {
        self.voice = voice
        self.values = defaults
    }

    public subscript(_ name: String) -> Double {
        get { values[name] ?? 0.5 }
        set { values[name] = min(1, max(0, newValue)) }
    }

    public var names: [String] { Array(values.keys).sorted() }
}

public enum Defaults {
    public static func params(for voice: Voice) -> ParamSet {
        switch voice {
        case .drums:
            return ParamSet(voice: .drums, defaults: [
                "amount": 0.5,
                // Three density lanes: `density` = hats, `punch` = the big
                // drums (kick/snare/clap decoration), `perc` = percs/effects.
                "density": 0.68, "punch": 0.72, "perc": 0.5,
                "swing": 0.18, "ghost": 0.32, "ratchet": 0.18,
                "fills": 0.58, "poly": 0.2, "recur": 0.55, "dynamics": 0.68,
                "humanize": 0.4, "kit": 0.5,
            ])
        case .bass:
            return ParamSet(voice: .bass, defaults: [
                "amount": 0.46,
                "density": 0.35, "octave": 0.3, "glide": 0.30, "accent": 0.62,
                "follow": 0.85, "approach": 0.30, "recur": 0.55,
            ])
        case .chords:
            return ParamSet(voice: .chords, defaults: [
                "amount": 0.46,
                "register": 0.50, "spread": 1.0, "humanize": 0.40,
            ])
        case .melody:
            return ParamSet(voice: .melody, defaults: [
                "amount": 0.34,
                "density": 0.28, "rest": 0.68, "register": 0.27,
                "length": 0.52, "motion": 0.42, "dynamics": 0.62,
                "repeat": 0.56, "contour": 0.38, "glide": 0.2, "humanize": 0.42,
            ])
        case .drone:
            return ParamSet(voice: .drone, defaults: [
                "register": 0.26, "fifth": 1.0, "width": 1.0, "swell": 0.72,
            ])
        case .pulse:
            return ParamSet(voice: .pulse, defaults: [
                "amount": 0.35, "density": 0.30, "division": 0.50,
                "gate": 0.40, "octave": 0.50, "recur": 0.70,
                "ratchet": 0.15, "dynamics": 0.60, "humanize": 0.35,
            ])
        }
    }

    /// Display order for the UI (dictionary order is meaningless).
    public static func order(for voice: Voice) -> [String] {
        switch voice {
        case .drums:  return ["amount", "punch", "density", "perc", "swing", "ghost", "ratchet", "fills", "poly", "recur", "dynamics", "humanize", "kit"]
        case .bass:   return ["amount", "density", "octave", "follow", "approach", "accent", "glide", "recur"]
        case .chords: return ["amount", "register", "spread", "humanize"]
        case .melody: return ["amount", "density", "rest", "register", "length",
                              "dynamics", "motion", "repeat", "contour", "glide", "humanize"]
        case .drone:  return ["register", "fifth", "width", "swell"]
        case .pulse:  return ["amount", "density", "division", "gate", "octave", "recur",
                              "ratchet", "dynamics", "humanize"]
        }
    }
}

/// Map a 0...1 octave knob to a whole-octave shift: thirds → −12 / 0 / +12.
public func octaveShift(_ v: Double) -> Int {
    Int(((v - 0.5) * 2).rounded()) * 12
}

/// Map a 0...1 length knob to a note-duration scale: 0.25× – 1.75×, 1× at
/// center.
public func lengthScale(_ v: Double) -> Double {
    0.25 + v * 1.5
}

/// Global, meta-generative controls — the knobs over change itself.
public struct EvolutionControls: Sendable {
    /// Per-voice: how far parameters may wander under modulation. 0 = frozen.
    public var drift: [Voice: Double] = [.drums: 0.5, .bass: 0.5, .chords: 0.5,
                                         .melody: 0.5, .drone: 0.5, .pulse: 0.5]
    /// Master speed of all slow modulation (scales source time).
    public var evolutionRate: Double = 0.5
    /// Thematic vs through-composed (melody/bass motif recall probability).
    public var motifRecurrence: Double = 0.68
    /// Macro clock: nominal bars per section (mapped from 0...1 to 4...64).
    public var sectionLength: Double = 0.30
    /// How correlated the voices' evolution is (shared vs independent walks).
    public var link: Double = 0.35
    /// How often the progression substitutes functional neighbors for the
    /// bank's classic chords (never on cadence steps). 0 = pure classics.
    public var wander: Double = 0.42
    /// Friction. Raises the chromatic allowance (passing tones, rubs,
    /// borrowed chords, clusters), widens dynamics, and makes structural
    /// disruptions more frequent. 0 = the old strictly-consonant engine.
    public var grit: Double = 0
    /// Master energy: scales every voice's presence and density at once.
    /// 0.5 = follow the conductor, 0 = space, 1 = everyone plays.
    public var push: Double = 0.5
    /// Nil keeps the groove seeded/autonomous; a value explicitly directs it.
    public var grooveStyle: DrumGenerator.GrooveStyle?
    /// Absolute-bar live cues layered over the autonomous conductor.
    public var arrangementCues: [ArrangementCue] = []
    /// Per-voice lock: freeze params + sub-seed while everything else evolves.
    public var locked: [Voice: Bool] = [.drums: false, .bass: false, .chords: false,
                                        .melody: false, .drone: false, .pulse: false]

    public init() {}

    public var sectionBars: Int {
        4 + Int((sectionLength * 60).rounded())
    }
}
