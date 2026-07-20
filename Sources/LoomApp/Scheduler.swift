import Foundation
import LoomCore

/// The threading rule from the design doc: clock → generation (lookahead, on
/// a worker thread) → scheduled MIDI. One bar is generated ahead of the
/// playhead; events go out with mach-time timestamps (CoreMIDI delivers them
/// precisely), each voice on its own virtual port, plus 24 PPQN clock on the
/// clock port so a DAW can slave its tempo.
final class Scheduler {
    let engine: Engine
    let midi: MIDIOut
    let monitor: ReferenceMonitor
    let clockInput: MIDIClockInput

    private let lock = NSLock()
    private let transportLock = NSLock()
    private var thread: Thread?
    private(set) var playing = false
    private(set) var clockMode: ClockMode = .internalClock
    private var clockPLL = MIDIClockPLL()
    private var pendingSongPosition = 0
    private var externalStartHost: UInt64 = 0

    private var timebase = mach_timebase_info_data_t()
    private var nextBar = 0
    private var nextBarHost: UInt64 = 0
    private var currentBarHost: UInt64 = 0
    private var currentBarDur: Double = 2.0
    private var currentBarIndex = 0
    /// Latest host time of anything already handed to CoreMIDI — events with
    /// future timestamps can't be recalled, so stop() must silence past this.
    private var scheduledHorizon: UInt64 = 0
    /// Last CC value sent per (port, controller) — the engine emits full
    /// deterministic sample sets; only changes go out the wire.
    private var lastCC: [Int: Int] = [:]

    /// Called from the worker thread after each generated bar.
    var onSnapshot: ((EngineSnapshot) -> Void)?
    var onTransport: ((Bool) -> Void)?

    init(engine: Engine, midi: MIDIOut, monitor: ReferenceMonitor) {
        self.engine = engine
        self.midi = midi
        self.monitor = monitor
        self.clockInput = MIDIClockInput()
        mach_timebase_info(&timebase)
        clockInput.onMessage = { [weak self] message in self?.handleClock(message) }
    }

    // MARK: time helpers

    private func hostNow() -> UInt64 { mach_absolute_time() }

    private func secondsToHost(_ s: Double) -> UInt64 {
        UInt64(s * 1e9 * Double(timebase.denom) / Double(timebase.numer))
    }

    private func hostToSeconds(_ h: UInt64) -> Double {
        Double(h) * Double(timebase.numer) / Double(timebase.denom) / 1e9
    }

    /// Serialize any engine mutation from the UI against generation.
    func withEngine(_ body: (Engine) -> Void) {
        lock.lock()
        body(engine)
        lock.unlock()
    }

    /// Where the playhead is right now, for the UI.
    func playhead() -> (bar: Int, phase: Double) {
        let now = hostNow()
        guard playing, currentBarHost > 0 else { return (currentBarIndex, 0) }
        if now < currentBarHost { return (max(0, currentBarIndex - 1), 1) }
        let phase = hostToSeconds(now - currentBarHost) / currentBarDur
        return (currentBarIndex, min(1, phase))
    }

    // MARK: transport

    func setClockMode(_ mode: ClockMode) {
        guard mode != clockMode else { return }
        if playing { stop() }
        transportLock.lock()
        clockMode = mode
        clockPLL.reset()
        pendingSongPosition = 0
        externalStartHost = 0
        transportLock.unlock()
    }

    var measuredTempo: Double? {
        transportLock.lock(); defer { transportLock.unlock() }
        return clockPLL.bpm
    }

    func play() {
        guard clockMode == .internalClock else { return }
        guard !playing else { return }
        playing = true
        lastCC.removeAll()
        nextBarHost = hostNow() + secondsToHost(0.2)
        midi.system(0xFA, hostTime: 0) // Start: receiver begins on next tick
        let t = Thread { [weak self] in self?.runLoop() }
        t.name = "loom.generation"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
        onTransport?(true)
    }

    func stop() {
        playing = false
        thread = nil
        if clockMode == .internalClock { midi.system(0xFC, hostTime: 0) }
        // Silence both now and just past the note-ons already in flight.
        // Note-ons are never scheduled more than a bar ahead, so two bars
        // covers them; drone note-offs queued further out fire harmlessly
        // into silence (don't wait 45 s to flush).
        midi.allNotesOff()
        monitor.allNotesOff()
        midi.allNotesOff(hostTime: hostNow() &+ secondsToHost(2 * currentBarDur))
        onTransport?(false)
    }

    /// Emergency silence without changing transport or generative state.
    func panic() {
        midi.allNotesOff()
        monitor.allNotesOff()
        midi.allNotesOff(hostTime: hostNow() &+ secondsToHost(2 * currentBarDur))
    }

    func rewind() {
        let wasPlaying = playing
        if wasPlaying { stop() }
        lock.lock()
        engine.rewind()
        lock.unlock()
        nextBar = 0
        currentBarIndex = 0
        currentBarHost = 0
        if wasPlaying { play() }
    }

    // MARK: generation loop

    private func runLoop() {
        while playing {
            let now = hostNow()
            transportLock.lock()
            let external = clockMode == .externalClock
            let lastTick = clockPLL.lastTickHost
            let began = externalStartHost
            transportLock.unlock()
            if external {
                let reference = lastTick ?? (began > 0 ? began : nil)
                if let reference, now > reference,
                   hostToSeconds(now - reference) > 0.5 {
                    stop()
                    break
                }
            }
            let lookahead = secondsToHost(0.35)
            if nextBarHost < now &+ lookahead {
                generateAndSchedule()
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    private func generateAndSchedule() {
        transportLock.lock()
        let mode = clockMode
        let followedTempo = clockPLL.bpm
        transportLock.unlock()
        lock.lock()
        let tempo = mode == .externalClock ? (followedTempo ?? engine.tempo) : engine.tempo
        if mode == .externalClock { engine.tempo = min(300, max(30, tempo)) }
        let output = engine.generateBar(nextBar)
        lock.unlock()

        let stepDur = (60.0 / tempo) / Double(stepsPerBeat)
        let barDur = stepDur * Double(stepsPerBar)
        let barStart = nextBarHost

        for e in output.events {
            let port = MIDIOut.Port(voice: e.voice)
            let start = barStart &+ secondsToHost(e.soundingStep * stepDur)
            let durSec = max(0.03, e.durationSteps * stepDur)
            let off = start &+ secondsToHost(durSec)
            midi.noteOn(port: port, note: e.note, velocity: e.velocity, hostTime: start)
            midi.noteOff(port: port, note: e.note, hostTime: off)
            let delay = start > hostNow() ? hostToSeconds(start - hostNow()) : 0
            monitor.schedule(e, delay: delay, duration: durSec)
            if e.voice == .melody || e.voice == .bass {
                midi.channelPressure(port: port, value: Int(Double(e.velocity) * 0.72),
                                     hostTime: start)
            }
            if e.glide && (e.voice == .melody || e.voice == .bass) {
                // Standard mono-synth portamento. Overlap in the generated
                // notes supplies legato; these messages make the glide hint
                // audible on synths that honor the General MIDI controllers.
                midi.cc(port: port, controller: 5, value: 38, hostTime: start)
                midi.cc(port: port, controller: 65, value: 127, hostTime: start)
                midi.cc(port: port, controller: 65, value: 0, hostTime: off)
            }
            if off > scheduledHorizon { scheduledHorizon = off }
        }

        // CC lanes, deduplicated per (port, controller).
        for c in output.controls {
            let port = MIDIOut.Port(voice: c.voice)
            let key = MIDIOut.Port.allCases.firstIndex(of: port)! << 8 | c.controller
            guard lastCC[key] != c.value else { continue }
            lastCC[key] = c.value
            midi.cc(port: port, controller: c.controller, value: c.value,
                    hostTime: barStart &+ secondsToHost(c.startStep * stepDur))
        }

        // 24 PPQN clock: 96 ticks across the bar's 4 beats.
        if mode == .internalClock {
            let ticks = 24 * stepsPerBar / stepsPerBeat
            for k in 0..<ticks {
                midi.system(0xF8, hostTime: barStart &+ secondsToHost(Double(k) * barDur / Double(ticks)))
            }
        }

        currentBarHost = barStart
        currentBarDur = barDur
        currentBarIndex = nextBar
        nextBar += 1
        nextBarHost = barStart &+ secondsToHost(barDur)
        if nextBarHost > scheduledHorizon { scheduledHorizon = nextBarHost }
        onSnapshot?(output.snapshot)
    }

    // MARK: external clock

    private func handleClock(_ message: MIDIClockMessage) {
        transportLock.lock()
        let follows = clockMode == .externalClock
        transportLock.unlock()
        guard follows else { return }

        switch message {
        case .songPosition(let sixteenths):
            transportLock.lock(); pendingSongPosition = max(0, sixteenths); transportLock.unlock()
        case .start(let host):
            startExternal(at: host, continueFromPosition: false)
        case .continue(let host):
            startExternal(at: host, continueFromPosition: true)
        case .stop:
            if playing { stop() }
        case .tick(let host):
            guard playing else { return }
            transportLock.lock()
            clockPLL.acceptTick(hostTime: host, secondsBetween: hostToSeconds)
            let tick = max(0, clockPLL.ticksSinceStart - 1)
            let tickInBar = tick % 96
            let interval = clockPLL.tickSeconds
            transportLock.unlock()

            // Beat four predicts the next downbeat. Correct only a bar that
            // has not yet been handed to CoreMIDI.
            if tickInBar >= 72, let interval {
                let predicted = host &+ secondsToHost(Double(96 - tickInBar) * interval)
                let clockBar = currentBarIndex + 1
                if nextBar == clockBar { nextBarHost = predicted }
            }
        }
    }

    private func startExternal(at host: UInt64, continueFromPosition: Bool) {
        if playing { stop() }
        transportLock.lock()
        clockPLL.reset()
        externalStartHost = host
        let startBar = continueFromPosition ? pendingSongPosition / stepsPerBar : 0
        if !continueFromPosition { pendingSongPosition = 0 }
        transportLock.unlock()

        playing = true
        lastCC.removeAll()
        nextBar = startBar
        currentBarIndex = startBar
        currentBarHost = host
        nextBarHost = host &+ secondsToHost(0.015)
        let t = Thread { [weak self] in self?.runLoop() }
        t.name = "loom.external-clock"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
        onTransport?(true)
    }
}
