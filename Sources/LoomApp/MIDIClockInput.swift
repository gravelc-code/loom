import Foundation
import CoreMIDI

enum ClockMode: String, CaseIterable, Codable, Sendable {
    case internalClock = "loom master"
    case externalClock = "ableton master"
}

enum MIDIClockMessage: Sendable {
    case tick(UInt64)
    case start(UInt64)
    case `continue`(UInt64)
    case stop(UInt64)
    case songPosition(Int)
}

/// Virtual CoreMIDI destination used when Ableton owns transport. Parsing is
/// intentionally limited to system realtime plus Song Position Pointer;
/// channel messages are irrelevant to the scheduler.
final class MIDIClockInput {
    private var client = MIDIClientRef()
    private var destination = MIDIEndpointRef()
    private let parseLock = NSLock()
    private var sppBytes: [UInt8] = []
    private var readingSPP = false
    var onMessage: ((MIDIClockMessage) -> Void)?
    private(set) var available = false

    init() {
        guard MIDIClientCreate("loom sync input" as CFString, nil, nil, &client) == noErr else {
            return
        }
        let ref = Unmanaged.passUnretained(self).toOpaque()
        let status = MIDIDestinationCreate(client, "loom sync in" as CFString,
                                           { packetList, readRef, _ in
            guard let readRef else { return }
            let input = Unmanaged<MIDIClockInput>.fromOpaque(readRef).takeUnretainedValue()
            input.receive(packetList)
        }, ref, &destination)
        available = status == noErr
    }

    private func receive(_ packetList: UnsafePointer<MIDIPacketList>) {
        parseLock.lock(); defer { parseLock.unlock() }
        var packet = packetList.pointee.packet
        for _ in 0..<packetList.pointee.numPackets {
            let timestamp = packet.timeStamp == 0 ? mach_absolute_time() : packet.timeStamp
            withUnsafeBytes(of: &packet.data) { raw in
                for byte in raw.prefix(Int(packet.length)) {
                    consume(byte, timestamp: timestamp)
                }
            }
            packet = MIDIPacketNext(&packet).pointee
        }
    }

    private func consume(_ byte: UInt8, timestamp: UInt64) {
        // Realtime bytes may appear between the two SPP data bytes.
        switch byte {
        case 0xF8: onMessage?(.tick(timestamp)); return
        case 0xFA: sppBytes.removeAll(); readingSPP = false; onMessage?(.start(timestamp)); return
        case 0xFB: onMessage?(.continue(timestamp)); return
        case 0xFC: onMessage?(.stop(timestamp)); return
        case 0xF2:
            sppBytes.removeAll(keepingCapacity: true)
            readingSPP = true
            return
        default: break
        }
        guard readingSPP, byte < 0x80, sppBytes.count < 2 else {
            if byte >= 0x80 { sppBytes.removeAll(); readingSPP = false }
            return
        }
        sppBytes.append(byte)
        if sppBytes.count == 2 {
            onMessage?(.songPosition(Int(sppBytes[0]) | (Int(sppBytes[1]) << 7)))
            sppBytes.removeAll(keepingCapacity: true)
            readingSPP = false
        }
    }
}
