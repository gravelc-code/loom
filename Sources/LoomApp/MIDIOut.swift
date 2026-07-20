import Foundation
import CoreMIDI
import LoomCore

/// MIDI-first output: one virtual CoreMIDI source per voice plus a clock
/// port ("loom drums" / "loom bass" / "loom chords" / "loom melody" /
/// "loom drone" / "loom pulse" / "loom clock"), so each DAW track takes its own port as
/// MIDI-From with no channel filtering. Events carry mach-time timestamps so
/// CoreMIDI delivers them sample-accurately regardless of when we enqueue.
final class MIDIOut {
    enum Port: String, CaseIterable {
        case drums, bass, chords, melody, drone, pulse, clock

        init(voice: Voice) {
            switch voice {
            case .drums:  self = .drums
            case .bass:   self = .bass
            case .chords: self = .chords
            case .melody: self = .melody
            case .drone:  self = .drone
            case .pulse:  self = .pulse
            }
        }

        var displayName: String { "loom \(rawValue)" }
        var uniqueIDKey: String { "loom.midi.uniqueID.\(rawValue)" }
    }

    static let voicePorts: [Port] = Port.allCases.filter { $0 != .clock }

    private var client = MIDIClientRef()
    private var sources: [Port: MIDIEndpointRef] = [:]
    private(set) var available = false

    init() {
        let status = MIDIClientCreateWithBlock("loom" as CFString, &client, nil)
        guard status == noErr else { return }
        for port in Port.allCases {
            var source = MIDIEndpointRef()
            guard MIDISourceCreateWithProtocol(client, port.displayName as CFString,
                                               ._1_0, &source) == noErr else { continue }
            claimStableUniqueID(for: source, port: port)
            sources[port] = source
        }
        available = sources.count == Port.allCases.count
    }

    /// DAWs reference MIDI inputs by uniqueID, and virtual sources get a
    /// random one each launch unless pinned — without this, Ableton track
    /// routings break on every relaunch. Reuse the last accepted ID (falling
    /// back to a fixed base), retrying past collisions with other devices.
    private func claimStableUniqueID(for endpoint: MIDIEndpointRef, port: Port) {
        let defaults = UserDefaults.standard
        let stored = defaults.integer(forKey: port.uniqueIDKey)
        // Fixed legacy slots preserve every pre-pulse endpoint identity.
        let slot: Int32
        switch port {
        case .drums: slot = 0
        case .bass: slot = 1
        case .chords: slot = 2
        case .melody: slot = 3
        case .drone: slot = 4
        case .clock: slot = 5
        case .pulse: slot = 6
        }
        var candidate = stored != 0 ? Int32(truncatingIfNeeded: stored)
                                    : 0x4C4D_0000 + slot
        for attempt in 0..<8 {
            let status = MIDIObjectSetIntegerProperty(endpoint, kMIDIPropertyUniqueID, candidate)
            if status == noErr {
                defaults.set(Int(candidate), forKey: port.uniqueIDKey)
                return
            }
            guard status == kMIDIIDNotUnique else { return }
            candidate &+= Int32(16 + attempt)
        }
    }

    // MARK: sending

    private func send(word: UInt32, to port: Port, hostTime: UInt64) {
        guard let source = sources[port] else { return }
        var list = MIDIEventList()
        let packet = MIDIEventListInit(&list, ._1_0)
        _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, hostTime, 1, [word])
        MIDIReceivedEventList(source, &list)
    }

    /// MIDI 1.0 channel-voice message as a UMP word (message type 2).
    private func channelVoice(_ status: UInt8, _ data1: UInt8, _ data2: UInt8) -> UInt32 {
        (0x2 << 28) | (UInt32(status) << 16) | (UInt32(data1) << 8) | UInt32(data2)
    }

    func noteOn(port: Port, note: Int, velocity: Int, hostTime: UInt64) {
        send(word: channelVoice(0x90, UInt8(min(127, max(0, note))),
                                UInt8(min(127, max(1, velocity)))),
             to: port, hostTime: hostTime)
    }

    func noteOff(port: Port, note: Int, hostTime: UInt64) {
        send(word: channelVoice(0x80, UInt8(min(127, max(0, note))), 0),
             to: port, hostTime: hostTime)
    }

    func cc(port: Port, controller: Int, value: Int, hostTime: UInt64) {
        send(word: channelVoice(0xB0, UInt8(min(127, max(0, controller))),
                                UInt8(min(127, max(0, value)))),
             to: port, hostTime: hostTime)
    }

    func channelPressure(port: Port, value: Int, hostTime: UInt64) {
        send(word: channelVoice(0xD0, UInt8(min(127, max(0, value))), 0),
             to: port, hostTime: hostTime)
    }

    /// System real-time (clock 0xF8 / start 0xFA / stop 0xFC) on the clock
    /// port — UMP message type 1, not the channel-voice word.
    func system(_ status: UInt8, hostTime: UInt64) {
        send(word: (0x1 << 28) | (UInt32(status) << 16), to: .clock, hostTime: hostTime)
    }

    /// CC 123 (all notes off) + CC 120 (all sound off) on every voice port.
    /// hostTime 0 = immediately; pass a future timestamp to also silence
    /// notes already handed to CoreMIDI (scheduled events can't be recalled).
    func allNotesOff(hostTime: UInt64 = 0) {
        for port in MIDIOut.voicePorts {
            cc(port: port, controller: 123, value: 0, hostTime: hostTime)
            cc(port: port, controller: 120, value: 0, hostTime: hostTime)
        }
    }
}
