import Foundation

/// Velocity as structure, not noise. Every shaping function here is a pure
/// function of musical position (step in bar, bar in phrase), so dynamics
/// mean something: the meter is audible, phrases point at their cadences,
/// and a recalled motif repeats its dynamic gesture along with its pitches.
/// The correlated `Feel` walk stays responsible for micro-level humanity;
/// this layer is the *statement*.
public enum Dynamics {
    /// Metric accent weight 0...1 for a grid position within the bar:
    /// downbeat strongest, mid-bar backbeat next, then beats, 8ths, 16ths.
    public static func metricWeight(step: Double) -> Double {
        let s = step.truncatingRemainder(dividingBy: Double(stepsPerBar))
        let i = Int(s.rounded())
        guard abs(s - Double(i)) < 0.3 else { return 0.35 } // off-grid
        switch ((i % 16) + 16) % 16 {
        case 0:             return 1.0
        case 8:             return 0.85
        case 4, 12:         return 0.7
        case 2, 6, 10, 14:  return 0.5
        default:            return 0.35
        }
    }

    /// Metric accent as a velocity multiplier (≈ 0.88 – 1.06).
    public static func metricAccent(step: Double) -> Double {
        0.88 + metricWeight(step: step) * 0.18
    }

    /// Phrase envelope multiplier: a gentle hairpin that rises through the
    /// phrase and settles on the cadence bar — the crescendo points at the
    /// resolution, the resolution itself relaxes.
    public static func phraseArc(barInPhrase: Int, phraseBars: Int) -> Double {
        guard phraseBars > 1 else { return 1.0 }
        if barInPhrase >= phraseBars - 1 { return 1.0 }
        let x = Double(barInPhrase) / Double(phraseBars - 1)
        return 0.94 + x * 0.12
    }

    /// Fold a shaping multiplier toward 1 by `amount` (0 = flat, 1 = full) —
    /// how the per-voice `dynamics` knob scales all of the above.
    public static func scaled(_ mul: Double, amount: Double) -> Double {
        1 + (mul - 1) * amount
    }
}
