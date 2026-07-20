import Foundation
import LoomCore

/// A small, shareable description of a performance. Runtime history is not
/// serialized: seed + controls regenerate it exactly from bar zero.
struct PerformanceState: Codable, Sendable {
    var version = 3
    var name: String
    var seed: UInt64
    var tempo: Double
    var key: Int
    var scale: Scale
    var params: [String: [String: Double]]
    var drift: [String: Double]
    var locked: [String: Bool]
    var muted: [String: Bool]
    var evolutionRate: Double
    var motifRecurrence: Double
    var sectionLength: Double
    var link: Double
    var wander: Double
    var grit: Double
    var push: Double
    /// Nil means the seed chooses autonomously.
    var grooveStyle: DrumGenerator.GrooveStyle? = nil
    var harmonyDialect: HarmonicDialect? = nil
    /// Optional keeps version-1 synthesized decoding backward compatible.
    var arrangementCues: [ArrangementCue]? = nil
    var clockMode: ClockMode? = nil
    /// Optional keeps older saved states decodable; applied as 0.5 when absent.
    var transitions: Double? = nil

    func value<T>(_ map: [String: T], for voice: Voice, default fallback: T) -> T {
        map[voice.rawValue] ?? fallback
    }

    /// Continuous interpolation for performance morphing. Identity and tonal
    /// law remain those of the source while the panel travels; recalling a
    /// slot is the explicit operation that changes seed/key/scale.
    func morphed(toward target: PerformanceState, amount: Double) -> PerformanceState {
        let t = min(1, max(0, amount))
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
        var out = self
        out.tempo = mix(tempo, target.tempo)
        out.evolutionRate = mix(evolutionRate, target.evolutionRate)
        out.motifRecurrence = mix(motifRecurrence, target.motifRecurrence)
        out.sectionLength = mix(sectionLength, target.sectionLength)
        out.link = mix(link, target.link)
        out.wander = mix(wander, target.wander)
        out.grit = mix(grit, target.grit)
        out.push = mix(push, target.push)
        out.transitions = mix(transitions ?? 0.5, target.transitions ?? 0.5)
        for voice in Voice.allCases {
            let key = voice.rawValue
            out.drift[key] = mix(drift[key] ?? 0.5, target.drift[key] ?? 0.5)
            var p = params[key] ?? [:]
            for (name, b) in target.params[key] ?? [:] {
                p[name] = mix(p[name] ?? b, b)
            }
            out.params[key] = p
        }
        return out
    }

    func makeEngine() -> Engine {
        let engine = Engine(seed: seed)
        apply(to: engine, includeIdentity: true)
        engine.rewind()
        return engine
    }

    /// Merge a saved dictionary into today's audited parameter schema. This
    /// both filters retired controls and translates the former two-control
    /// register systems without changing the sound of existing files.
    func migratedParams(for voice: Voice) -> [String: Double] {
        let saved = params[voice.rawValue] ?? [:]
        var result = Defaults.params(for: voice).values
        for key in Array(result.keys) {
            if let value = saved[key] { result[key] = min(1, max(0, value)) }
        }

        switch voice {
        case .chords:
            if saved["register"] == nil,
               saved["voicing"] != nil || saved["octave"] != nil {
                let center = 56.0 + (saved["voicing"] ?? 0.42) * 10.0
                    + Double(octaveShift(saved["octave"] ?? 0.5))
                result["register"] = min(1, max(0, (center - 48.0) / 24.0))
            }
            result["spread"] = (saved["spread"] ?? result["spread"] ?? 1) > 0.5 ? 1 : 0

        case .melody:
            if saved["register"] == nil,
               saved["range"] != nil || saved["octave"] != nil {
                let center = 60.0 + ((saved["range"] ?? 0.46) - 0.5) * 24.0
                    + Double(octaveShift(saved["octave"] ?? 0.5))
                result["register"] = min(1, max(0, (center - 52.0) / 30.0))
            }
            result["contour"] = canonicalThird(saved["contour"] ?? result["contour"] ?? 0.5)

        case .drone:
            result["fifth"] = (saved["fifth"] ?? result["fifth"] ?? 1) > 0.25 ? 1 : 0
            result["width"] = (saved["width"] ?? result["width"] ?? 1) > 0.55 ? 1 : 0

        case .bass:
            result["octave"] = canonicalThird(saved["octave"] ?? result["octave"] ?? 0.5)

        case .pulse:
            result["octave"] = canonicalThird(saved["octave"] ?? result["octave"] ?? 0.5)
            result["division"] = canonicalThird(saved["division"] ?? result["division"] ?? 0.5)

        case .drums:
            let poly = saved["poly"] ?? result["poly"] ?? 0
            result["poly"] = poly <= 0.65 ? 0 : (poly < 0.90 ? 0.78 : 1)
        }
        return result
    }

    private func canonicalThird(_ value: Double) -> Double {
        value < 0.34 ? 0 : (value < 0.67 ? 0.5 : 1)
    }

    func apply(to engine: Engine, includeIdentity: Bool) {
        if includeIdentity {
            engine.reseed(seed)
            engine.harmonyEngine.key = key
            engine.harmonyEngine.scale = scale
        }
        engine.tempo = tempo
        for voice in Voice.allCases {
            engine.params[voice] = ParamSet(voice: voice,
                                            defaults: migratedParams(for: voice))
            engine.evolution.drift[voice] = value(drift, for: voice, default: 0.5)
            engine.evolution.locked[voice] = value(locked, for: voice, default: false)
            engine.muted[voice] = value(muted, for: voice, default: false)
        }
        engine.evolution.evolutionRate = evolutionRate
        engine.evolution.motifRecurrence = motifRecurrence
        engine.evolution.sectionLength = sectionLength
        engine.evolution.link = link
        engine.evolution.wander = wander
        engine.evolution.grit = grit
        engine.evolution.push = push
        engine.evolution.transitions = transitions ?? 0.5
        engine.evolution.grooveStyle = grooveStyle
        engine.evolution.arrangementCues = arrangementCues ?? []
        engine.harmonyEngine.dialectOverride = harmonyDialect
    }
}
