import Foundation
import LoomCore

/// Deterministic Standard MIDI File renderer. Format 1 keeps Loom's six
/// musical ports as independent tracks so the file drops into a DAW already
/// separated into drone, drums, bass, chords, pulse and melody.
enum MIDIFileExporter {
    static let ppq = 480

    private struct Event {
        let tick: Int
        let priority: Int
        let bytes: [UInt8]
    }

    static func render(_ state: PerformanceState, bars: Int) -> Data {
        let engine = state.makeEngine()
        let count = max(1, bars)
        var perVoice: [Voice: [Event]] = Dictionary(uniqueKeysWithValues:
            Voice.allCases.map { ($0, []) })

        for bar in 0..<count {
            let output = engine.generateBar(bar)
            for note in output.events {
                let start = ticks(bar: bar, step: note.soundingStep)
                let end = max(start + 1, start + Int((note.durationSteps / 4 * Double(ppq)).rounded()))
                perVoice[note.voice, default: []].append(Event(
                    tick: start, priority: 1,
                    bytes: [0x90, UInt8(clamping: note.note), UInt8(clamping: note.velocity)]))
                perVoice[note.voice, default: []].append(Event(
                    tick: end, priority: 0,
                    bytes: [0x80, UInt8(clamping: note.note), 0]))
                if note.voice == .melody || note.voice == .bass {
                    perVoice[note.voice, default: []].append(Event(
                        tick: start, priority: 2,
                        bytes: [0xD0, UInt8(clamping: Int(Double(note.velocity) * 0.72))]))
                }
                if note.glide && (note.voice == .melody || note.voice == .bass) {
                    perVoice[note.voice, default: []].append(Event(
                        tick: start, priority: 2, bytes: [0xB0, 5, 38]))
                    perVoice[note.voice, default: []].append(Event(
                        tick: start, priority: 2, bytes: [0xB0, 65, 127]))
                    perVoice[note.voice, default: []].append(Event(
                        tick: end, priority: 2, bytes: [0xB0, 65, 0]))
                }
            }
            for cc in output.controls {
                perVoice[cc.voice, default: []].append(Event(
                    tick: ticks(bar: bar, step: cc.startStep), priority: 2,
                    bytes: [0xB0, UInt8(clamping: cc.controller), UInt8(clamping: cc.value)]))
            }
        }

        var data = Data()
        data.appendASCII("MThd")
        data.appendBE(UInt32(6))
        data.appendBE(UInt16(1))
        data.appendBE(UInt16(Voice.allCases.count + 1))
        data.appendBE(UInt16(ppq))
        data.append(trackChunk(tempoTrack(bpm: state.tempo)))
        for voice in Voice.allCases {
            data.append(trackChunk(trackBody(named: voice.rawValue,
                                             events: perVoice[voice] ?? [])))
        }
        return data
    }

    private static func ticks(bar: Int, step: Double) -> Int {
        bar * 4 * ppq + Int((step / 4 * Double(ppq)).rounded())
    }

    private static func tempoTrack(bpm: Double) -> Data {
        let micros = UInt32((60_000_000 / max(1, bpm)).rounded())
        var body = Data([0, 0xFF, 0x51, 3,
                         UInt8((micros >> 16) & 0xFF), UInt8((micros >> 8) & 0xFF), UInt8(micros & 0xFF)])
        body.append(contentsOf: [0, 0xFF, 0x58, 4, 4, 2, 24, 8])
        body.append(contentsOf: [0, 0xFF, 0x2F, 0])
        return body
    }

    private static func trackBody(named name: String, events: [Event]) -> Data {
        var body = Data()
        let nameBytes = Array(name.utf8.prefix(127))
        body.append(0)
        body.append(contentsOf: [0xFF, 0x03, UInt8(nameBytes.count)])
        body.append(contentsOf: nameBytes)
        var previous = 0
        for event in events.sorted(by: {
            $0.tick == $1.tick ? $0.priority < $1.priority : $0.tick < $1.tick
        }) {
            body.append(contentsOf: variableLength(max(0, event.tick - previous)))
            body.append(contentsOf: event.bytes)
            previous = event.tick
        }
        body.append(contentsOf: [0, 0xFF, 0x2F, 0])
        return body
    }

    private static func trackChunk(_ body: Data) -> Data {
        var out = Data()
        out.appendASCII("MTrk")
        out.appendBE(UInt32(body.count))
        out.append(body)
        return out
    }

    private static func variableLength(_ value: Int) -> [UInt8] {
        var value = max(0, value)
        var bytes = [UInt8(value & 0x7F)]
        value >>= 7
        while value > 0 {
            bytes.insert(UInt8(value & 0x7F) | 0x80, at: 0)
            value >>= 7
        }
        return bytes
    }
}

private extension UInt8 {
    init(clamping value: Int) { self = UInt8(Swift.max(0, Swift.min(127, value))) }
}

private extension Data {
    mutating func appendASCII(_ string: String) { append(contentsOf: string.utf8) }
    mutating func appendBE(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xFF)); append(UInt8(value & 0xFF))
    }
    mutating func appendBE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF)); append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF)); append(UInt8(value & 0xFF))
    }
}
