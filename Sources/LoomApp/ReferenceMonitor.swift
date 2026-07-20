import Foundation
import AVFoundation
import AudioToolbox
import LoomCore

/// A deliberately modest built-in interpretation of Loom's six voices.
/// It uses macOS's bundled General MIDI bank, so first launch can make sound
/// without shipping samples or turning Loom into a synthesis product.
final class ReferenceMonitor {
    private let engine = AVAudioEngine()
    private let tonalMixer = AVAudioMixerNode()
    private let darkEQ = AVAudioUnitEQ(numberOfBands: 1)
    private let reverb = AVAudioUnitReverb()
    private var samplers: [Voice: AVAudioUnitSampler] = [:]
    private let queue = DispatchQueue(label: "loom.reference-monitor")
    private let stateLock = NSLock()
    private var isEnabled = false

    init() {
        let bank = URL(fileURLWithPath:
            "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")
        let programs: [Voice: UInt8] = [
            .drone: 99, .drums: 0, .bass: 39, .chords: 95, .melody: 84,
            .pulse: 11,
        ]
        let levels: [Voice: Float] = [
            .drone: 0.30, .drums: 0.44, .bass: 0.36, .chords: 0.28, .melody: 0.22,
            .pulse: 0.20,
        ]
        engine.attach(tonalMixer)
        engine.attach(darkEQ)
        engine.attach(reverb)
        let lowPass = darkEQ.bands[0]
        lowPass.filterType = .lowPass
        lowPass.frequency = 5_800
        lowPass.bandwidth = 0.8
        lowPass.bypass = false
        reverb.loadFactoryPreset(.largeHall)
        reverb.wetDryMix = 28
        for voice in Voice.allCases {
            let sampler = AVAudioUnitSampler()
            engine.attach(sampler)
            // Keep the kick/snare immediate. The tonal GM voices share a
            // darkened hall so the sketch sounds like a space, not several
            // unrelated General MIDI presets in a lobby.
            engine.connect(sampler,
                           to: voice == .drums ? engine.mainMixerNode : tonalMixer,
                           format: nil)
            sampler.volume = levels[voice] ?? 0.3
            let percussion = voice == .drums
            try? sampler.loadSoundBankInstrument(
                at: bank, program: programs[voice] ?? 0,
                bankMSB: UInt8(percussion ? kAUSampler_DefaultPercussionBankMSB
                                          : kAUSampler_DefaultMelodicBankMSB),
                bankLSB: UInt8(kAUSampler_DefaultBankLSB))
            samplers[voice] = sampler
        }
        engine.connect(tonalMixer, to: darkEQ, format: nil)
        engine.connect(darkEQ, to: reverb, format: nil)
        engine.connect(reverb, to: engine.mainMixerNode, format: nil)
        engine.mainMixerNode.outputVolume = 0.65
        engine.prepare()
    }

    func setEnabled(_ enabled: Bool) {
        stateLock.lock(); isEnabled = enabled; stateLock.unlock()
        if enabled {
            if !engine.isRunning { try? engine.start() }
        } else {
            allNotesOff()
            engine.pause()
        }
    }

    func schedule(_ event: NoteEvent, delay: Double, duration: Double) {
        guard enabled else { return }
        let startDelay = max(0, delay)
        queue.asyncAfter(deadline: .now() + startDelay) { [weak self] in
            guard let self, self.enabled, let sampler = self.samplers[event.voice] else { return }
            sampler.startNote(UInt8(clamping: event.note),
                              withVelocity: UInt8(clamping: event.velocity), onChannel: 0)
            self.queue.asyncAfter(deadline: .now() + max(0.03, duration)) { [weak self] in
                self?.samplers[event.voice]?.stopNote(UInt8(clamping: event.note), onChannel: 0)
            }
        }
    }

    func audition(_ voice: Voice, note: Int, velocity: Int = 84) {
        guard enabled, let sampler = samplers[voice] else { return }
        sampler.startNote(UInt8(clamping: note), withVelocity: UInt8(clamping: velocity), onChannel: 0)
        queue.asyncAfter(deadline: .now() + 0.45) { [weak sampler] in
            sampler?.stopNote(UInt8(clamping: note), onChannel: 0)
        }
    }

    func allNotesOff() {
        for sampler in samplers.values {
            sampler.sendController(123, withValue: 0, onChannel: 0)
            sampler.sendController(120, withValue: 0, onChannel: 0)
        }
    }

    private var enabled: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return isEnabled
    }
}

private extension UInt8 {
    init(clamping value: Int) { self = UInt8(Swift.max(0, Swift.min(127, value))) }
}
