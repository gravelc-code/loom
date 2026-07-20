import Foundation

public enum Voice: String, CaseIterable, Codable, Sendable {
    // New voices are appended so the `firstIndex`-derived sub-seed / Feel /
    // modulation streams of existing voices stay byte-identical.
    case drums, bass, chords, melody, drone, pulse
}

/// Drum tracks inside the drums voice. Everything lives inside the 16-pad
/// Ableton Drum Rack range (notes 36–51 — a 4×4 grid), so a stock kit sounds
/// every hit. The core eight (kick…open hat) are the backbone; the `kit` width
/// control then layers in the rest — a shaker on pad 44 and the top row (48–51:
/// ride, crash and two one-shot pads), which is where drum racks keep their
/// cymbals and "up top" one-shots. New cases are appended so existing
/// rawValue-derived seeds stay stable.
public enum DrumTrack: Int, CaseIterable, Sendable {
    case kick, snare, hat, perc, glitch, clap, rim, hatOpen
    case shaker, ride, crash, oneShot, oneShotHi
    case accent, tomLo, tomHi

    /// General MIDI percussion notes (Ableton's default 16-pad layout, 36–51).
    public var note: Int {
        switch self {
        case .kick:      return 36
        case .rim:       return 37
        case .snare:     return 38
        case .clap:      return 39
        case .glitch:    return 43
        case .shaker:    return 44   // pad 9 — tight shaker/pedal-hat texture
        case .perc:      return 45
        case .hat:       return 42
        case .hatOpen:   return 46
        case .accent:    return 40   // electric snare / accent layer
        case .tomLo:     return 41   // low tom (fills)
        case .tomHi:     return 47   // mid tom (fills)
        case .oneShot:   return 48   // top row — kit-specific perc / one-shot
        case .crash:     return 49
        case .oneShotHi: return 50   // top row — kit-specific perc / one-shot
        case .ride:      return 51
        }
    }

    public var label: String {
        ["kick", "snare", "closed hat", "low tom", "floor tom", "clap", "side-stick",
         "open hat", "shaker", "ride", "crash", "perc", "top perc",
         "accent", "tom lo", "tom hi"][rawValue]
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
