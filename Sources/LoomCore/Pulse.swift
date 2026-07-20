import Foundation

/// Rhythmic harmony without another melody. The pulse holds one voice-led
/// current-chord tone for a two-bar cell, then repeats it on a small metric
/// vocabulary. Pitch never wanders independently of the pad; variation is
/// entirely rhythm, gate and dynamics.
public struct PulseGenerator {
    public static func generate(bar: Int, params: ParamSet, harmony: HarmonyContext,
                                subSeed: UInt64, feel: Feel, tension: Double,
                                ensemble: EnsembleContext, event: SectionEvent?,
                                friction: Double) -> [NoteEvent] {
        guard event != .vacuum && event != .exhale else { return [] }

        let density = params["density"]
        let division = params["division"]
        let gate = params["gate"]
        let recur = params["recur"]
        let ratchet = params["ratchet"]
        let dynamics = params["dynamics"]
        let humanize = params["humanize"]

        var profile = RNG(seed: hashSeed(subSeed, 0x5055_4C53,
                                        UInt64(max(0, harmony.phraseIndex / 2))))
        let center = 68 + octaveShift(params["octave"]) + profile.range(-3, 4).roundedInt
        let note = harmony.snapToChord(center)

        // Division is intentionally coarse: quarter / eighth / sixteenth.
        // Builds override it upstream, while ordinary bars favor a learnable
        // eighth-note cell rather than an arpeggiator cascade.
        let gridStride = division < 0.34 ? 4 : (division < 0.67 ? 2 : 1)
        var candidates = Array(Swift.stride(from: 0, to: stepsPerBar, by: gridStride))
        if event != .drop { candidates.removeAll { $0 == 0 } }

        let cycle = recur > 0.72 ? 4 : 2
        var recurrenceRNG = RNG(seed: hashSeed(subSeed, 0x5055_5243, UInt64(max(0, bar))))
        let patternBar = recurrenceRNG.chance(recur) ? bar % cycle : bar
        var events: [NoteEvent] = []
        var didFracture = false
        for step in candidates {
            var rng = RNG(seed: hashSeed(subSeed, 0x5055_4C45,
                                        UInt64(step), UInt64(max(0, patternBar))))
            let metric = Dynamics.metricAccent(step: Double(step))
            var chance = 0.08 + density * 0.62 + tension * 0.12
            if ensemble.anchors.contains(step) { chance += 0.12 }
            if step % 4 == 2 { chance += 0.08 }
            if event == .drop && step == 0 { chance = 1 }
            guard rng.chance(min(0.94, chance)) else { continue }

            let nextStep = candidates.first(where: { $0 > step }) ?? stepsPerBar
            let duration = max(0.25, min(Double(nextStep - step) * 0.82,
                                         0.2 + gate * Double(gridStride) * 0.9))
            var velocity = (43 + tension * 28) * Dynamics.scaled(metric, amount: dynamics)
            if event == .drop && step == 0 { velocity += 18 }
            var e = NoteEvent(voice: .pulse, note: note,
                              velocity: Int(min(112, max(20, velocity))),
                              startStep: Double(step), durationSteps: duration)
            feel.apply(to: &e, absoluteStep: Double(bar * stepsPerBar + step),
                       amount: humanize)
            events.append(e)

            // One deterministic fracture at most. It repeats the same pitch,
            // so increasing grit changes time without creating harmonic rub.
            let fracture = ratchet * (0.45 + friction * 0.55)
            if !didFracture && step != 0 && rng.chance(fracture * 0.22) {
                let spacing = gridStride == 1 ? 0.25 : 0.5
                var r = e
                r.startStep += spacing
                r.durationSteps = min(r.durationSteps, spacing * 0.75)
                r.velocity = max(18, Int(Double(r.velocity) * 0.72))
                events.append(r)
                didFracture = true
            }
        }
        return events.sorted { ($0.startStep, $0.note) < ($1.startStep, $1.note) }
    }
}

private extension Double {
    var roundedInt: Int { Int(rounded()) }
}
