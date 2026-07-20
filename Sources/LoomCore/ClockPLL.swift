import Foundation

/// Smoothed MIDI-clock timing model. It accepts arbitrary host-time units via
/// the conversion closure, which keeps the estimator platform-independent and
/// directly testable without CoreMIDI.
public struct MIDIClockPLL: Sendable {
    public private(set) var tickSeconds: Double?
    public private(set) var lastTickHost: UInt64?
    public private(set) var ticksSinceStart = 0

    public init() {}

    public mutating func reset() {
        tickSeconds = nil
        lastTickHost = nil
        ticksSinceStart = 0
    }

    public mutating func acceptTick(hostTime: UInt64,
                                    secondsBetween: (UInt64) -> Double) {
        if let previous = lastTickHost, hostTime > previous {
            let interval = secondsBetween(hostTime - previous)
            if interval > 0.001, interval < 0.25 {
                tickSeconds = tickSeconds.map { $0 * 0.82 + interval * 0.18 } ?? interval
            }
        }
        lastTickHost = hostTime
        ticksSinceStart += 1
    }

    public var bpm: Double? {
        guard let tickSeconds, tickSeconds > 0 else { return nil }
        return 60 / (tickSeconds * 24)
    }
}
