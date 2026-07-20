import Foundation

public enum Voice: String, CaseIterable, Codable, Sendable {
    // New voices are appended so the `firstIndex`-derived sub-seed / Feel /
    // modulation streams of existing voices stay byte-identical.
    case drums, bass, chords, melody, drone, pulse
}

/// Drum tracks inside the drums voice.
public enum DrumTrack: Int, CaseIterable, Sendable {
    case kick, snare, hat, perc, glitch, clap, rim, hatOpen

    /// General MIDI percussion notes, matching Ableton's common kit layout:
    /// kick 36, side-stick 37, snare 38, clap 39, floor tom 43,
    /// low tom 45, closed hat 42 and open hat 46.
    public var note: Int {
        switch self {
        case .kick:    return 36
        case .rim:     return 37
        case .snare:   return 38
        case .clap:    return 39
        case .glitch:  return 43
        case .perc:    return 45
        case .hat:     return 42
        case .hatOpen: return 46
        }
    }

    public var label: String {
        ["kick", "snare", "closed hat", "low tom", "floor tom", "clap", "side-stick", "open hat"][rawValue]
    }
}

/// One generated note. Positions are in steps (16th notes) relative to the
/// start of the bar it was generated in; micro-timing lives in `timingOffset`
/// (fractions of a step) so the constraint pass can reason about the grid
/// position while humanize displaces the sounding time.
public struct NoteEvent: Sendable {
    public var voice: Voice
    public var note: Int
    public var velocity: Int        // 1...127
    public var startStep: Double    // grid position within the bar, 0..<16
    public var durationSteps: Double
    public var timingOffset: Double // humanize displacement, in steps
    public var glide: Bool          // legato/portamento hint

    public init(voice: Voice, note: Int, velocity: Int, startStep: Double,
                durationSteps: Double, timingOffset: Double = 0, glide: Bool = false) {
        self.voice = voice
        self.note = note
        self.velocity = velocity
        self.startStep = startStep
        self.durationSteps = durationSteps
        self.timingOffset = timingOffset
        self.glide = glide
    }

    /// Sounding position including humanize.
    public var soundingStep: Double { max(0, startStep + timingOffset) }
}

public let stepsPerBar = 16
public let stepsPerBeat = 4
