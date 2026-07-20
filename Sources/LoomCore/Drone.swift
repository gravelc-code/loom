import Foundation

/// The sustained foundation: a root (plus optional 5th and octave) held for a
/// whole drone span — minutes of unbroken low end that ties the ensemble
/// across chord changes. Emitted only in the span's start bar with a
/// multi-bar duration (the scheduler timestamps note-offs at emission), with
/// a one-step breath before the next span re-attacks. No humanize: the drone
/// is the fixed point everything else drifts against.
public struct DroneGenerator {
    /// The drone's lowest sounding pitch for a span — pure function of the
    /// span root and the register param, so any voice can recompute exactly
    /// where the drone sits (it can climb to ~A2 at a high register setting,
    /// which is why a bass-vs-drone clash must be judged in absolute pitch,
    /// not by pitch class).
    public static func rootNote(span: DroneSpan, register: Double) -> Int {
        let target = 24 + Int((register * 16).rounded())
        var root = 24 + ((span.rootPC - 24) % 12 + 12) % 12
        while root + 12 <= target + 6 { root += 12 }
        return root
    }

    /// Every pitch the drone actually holds across a span (root, plus 5th and
    /// octave when the params call for them). Sustains the whole span, so it is
    /// the sounding set at any bar the span covers.
    public static func notes(span: DroneSpan, params: ParamSet) -> [Int] {
        let root = rootNote(span: span, register: params["register"])
        var ns = [root]
        if params["fifth"] > 0.25 { ns.append(root + 7) }
        if params["width"] > 0.55 { ns.append(root + 12) }
        return ns
    }

    public static func generate(bar: Int, params: ParamSet, span: DroneSpan,
                                tension: Double) -> [NoteEvent] {
        guard bar == span.startBar else { return [] }

        let dur = Double(span.bars * stepsPerBar) - 1 // 1-step breath
        let vel = Int(48 + tension * 28)

        let notes = notes(span: span, params: params)

        return notes.enumerated().map { i, n in
            NoteEvent(voice: .drone, note: n,
                      velocity: max(1, vel - (i > 0 ? 8 : 0)),
                      startStep: 0, durationSteps: dur, glide: true)
        }
    }
}
