import Foundation
import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers
import LoomCore

/// The playhead's fast-moving state, isolated so only playhead-drawing
/// views observe it.
@MainActor
final class PlayheadModel: ObservableObject {
    @Published var bar = 0
    @Published var phase = 0.0
}

/// The field's per-bar grids, isolated so publishing two 48×48 arrays each
/// bar re-renders only the field panel.
@MainActor
final class FieldModel: ObservableObject {
    @Published var prev: [Float] = []
    @Published var curr: [Float] = []
    var stamp = Date.distantPast

    func accept(_ grid: [Float]) {
        prev = curr.isEmpty ? grid : curr
        curr = grid
        stamp = Date()
    }
}

/// Main-actor bridge between the engine (owned by the scheduler thread) and
/// the SwiftUI surface. All engine mutation goes through
/// `scheduler.withEngine`; the UI reads published snapshots.
@MainActor
final class AppModel: ObservableObject {
    let midi = MIDIOut()
    let monitor = ReferenceMonitor()
    let scheduler: Scheduler

    @Published var snapshot = EngineSnapshot()
    @Published var playing = false
    @Published var monitorEnabled = false {
        didSet { monitor.setEnabled(monitorEnabled) }
    }
    /// Fast-moving playhead state lives in its own object so the 15 Hz
    /// updates only re-render the views that draw the playhead. Publishing
    /// it through AppModel rebuilt the entire window continuously, which —
    /// among other costs — reset macOS's tooltip hover timer so `.help`
    /// tooltips never appeared.
    let playhead = PlayheadModel()
    /// Last two field grids + arrival time: the field view crossfades
    /// between them so the simulation visibly crawls instead of snapping
    /// once per bar.
    let field = FieldModel()
    /// Rolling weave window: recent generated bars' notes + tension. Kept deep
    /// enough that the piano roll can be scrolled back through the piece.
    @Published var roll: [(bar: Int, tension: Double, notes: [NoteSummary])] = []
    /// How many generated bars of history the roll retains.
    static let rollHistory = 64
    /// Provisional upcoming bars shown ahead of the playhead. Display-only:
    /// only the next bar is committed to MIDI, so these reshape as you edit.
    @Published var lookahead: [(bar: Int, notes: [NoteSummary])] = []
    /// Bumped whenever the roll restarts (rewind/reseed) so cached weave
    /// geometry for old bar numbers is discarded.
    var rollGeneration = 0
    /// Wall-clock moment of the last playhead poll — the tapestry
    /// extrapolates between 15 Hz ticks for a 60 fps glide.
    var playheadAnchor = Date.distantPast
    var barDuration: Double { 240.0 / max(1, tempo) }

    // Mirrors of engine state the user edits (pushed through withEngine).
    @Published var baseParams: [Voice: [String: Double]] = [:]
    @Published var drift: [Voice: Double] = [:]
    @Published var locked: [Voice: Bool] = [:]
    @Published var muted: [Voice: Bool] = [:]
    @Published var soloed: Voice?
    @Published var evolutionRate = 0.5 { didSet { push { $0.evolution.evolutionRate = self.evolutionRate } } }
    @Published var motifRecurrence = 0.68 { didSet { push { $0.evolution.motifRecurrence = self.motifRecurrence } } }
    @Published var sectionLength = 0.30 { didSet { push { $0.evolution.sectionLength = self.sectionLength } } }
    @Published var link = 0.35 { didSet { push { $0.evolution.link = self.link } } }
    @Published var wander = 0.42 { didSet { push { $0.evolution.wander = self.wander } } }
    @Published var grit = 0.45 { didSet { push { $0.evolution.grit = self.grit } } }
    @Published var performancePush = 0.5 { didSet { push { $0.evolution.push = self.performancePush } } }
    @Published var transitions = 0.5 { didSet { push { $0.evolution.transitions = self.transitions } } }
    @Published var tempo = 78.0 { didSet { push { $0.tempo = self.tempo } } }
    @Published var clockMode = ClockMode.internalClock {
        didSet { scheduler.setClockMode(clockMode) }
    }
    @Published var grooveStyle: DrumGenerator.GrooveStyle? {
        didSet { push { $0.evolution.grooveStyle = self.grooveStyle } }
    }
    @Published var harmonyDialect: HarmonicDialect? {
        didSet { push { $0.harmonyEngine.dialectOverride = self.harmonyDialect } }
    }
    @Published var key = 9 { didSet { push { $0.harmonyEngine.key = self.key } } }
    @Published var scaleChoice = Scale.minor { didSet { push { $0.harmonyEngine.scale = self.scaleChoice } } }
    @Published var seed: UInt64
    @Published var slotA: PerformanceState?
    @Published var slotB: PerformanceState?
    @Published var morphProgress: Double?
    @Published var statusMessage = ""
    @Published private(set) var canUndo = false

    private var timer: AnyCancellable?
    private var undoStack: [PerformanceState] = []
    private struct ActiveMorph {
        let from: PerformanceState
        let to: PerformanceState
        let startBar: Int
        let bars: Int
    }
    private var activeMorph: ActiveMorph?

    init() {
        let initialSeed = UInt64.random(in: 1..<UInt64.max)
        seed = initialSeed
        grooveStyle = nil
        harmonyDialect = nil
        let engine = Engine(seed: initialSeed)
        engine.tempo = 78
        engine.evolution.motifRecurrence = 0.68
        engine.evolution.sectionLength = 0.30
        engine.evolution.link = 0.35
        engine.evolution.wander = 0.42
        engine.evolution.grit = 0.45
        engine.evolution.push = 0.5
        engine.evolution.transitions = 0.5
        scheduler = Scheduler(engine: engine, midi: midi, monitor: monitor)
        // The engine seeds its own home key/scale; mirror it into the selectors
        // so the UI opens on the actual home rather than a stale default.
        // (Assignments inside init don't fire didSet, so no redundant push.)
        key = engine.harmonyEngine.key
        scaleChoice = engine.harmonyEngine.scale

        for v in Voice.allCases {
            baseParams[v] = Defaults.params(for: v).values
            drift[v] = 0.5
            locked[v] = false
            muted[v] = false
        }

        scheduler.onSnapshot = { [weak self] snap in
            DispatchQueue.main.async { self?.apply(snap) }
        }
        scheduler.onTransport = { [weak self] running in
            DispatchQueue.main.async {
                self?.playing = running
                if running { self?.statusMessage = "" }
                else { self?.lookahead = [] }   // no provisional future when stopped
            }
        }
        scheduler.onLookahead = { [weak self] la in
            DispatchQueue.main.async { self?.lookahead = la }
        }

        // Preview snapshot so harmony/field/arc panels aren't blank before
        // play. Generating bar 0 then rewinding leaves playback untouched.
        var preview: EngineSnapshot?
        scheduler.withEngine { e in
            preview = e.generateBar(0).snapshot
            e.rewind()
            // (generateBar advanced the field/motif state; rewind reset it.)
        }
        if let p = preview { apply(p) }
        timer = Timer.publish(every: 1.0 / 15.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    private func push(_ body: @escaping (Engine) -> Void) {
        scheduler.withEngine(body)
        scheduler.markLookaheadDirty()   // an edit changes the upcoming bars
    }

    private func tick() {
        let (bar, phase) = scheduler.playhead()
        // Publish only real changes: a no-op assignment still fires
        // objectWillChange and needlessly rebuilds observers.
        if bar != playhead.bar { playhead.bar = bar }
        if abs(phase - playhead.phase) > 0.0005 { playhead.phase = phase }
        playheadAnchor = Date()
        if clockMode == .externalClock, let followed = scheduler.measuredTempo,
           abs(tempo - followed) > 0.05 {
            tempo = followed
        }
    }

    private func apply(_ snap: EngineSnapshot) {
        snapshot = snap
        field.accept(snap.fieldGrid)
        if let last = roll.last, snap.bar <= last.bar { // rewind/reseed
            roll.removeAll()
            rollGeneration += 1
        }
        roll.append((snap.bar, snap.tension, snap.notes))
        if roll.count > Self.rollHistory { roll.removeFirst(roll.count - Self.rollHistory) }
        advanceMorph(at: snap.bar)
    }

    // MARK: user actions

    func togglePlay() {
        if clockMode == .externalClock {
            if playing {
                scheduler.stop()
            } else {
                statusMessage = "waiting for Ableton clock on loom sync in"
            }
            return
        }
        if playing {
            scheduler.stop()
        } else {
            scheduler.play()
        }
        playing.toggle()
    }

    func rewind() {
        scheduler.rewind()
        playhead.bar = 0
        playhead.phase = 0
        roll.removeAll()
        rollGeneration += 1
    }

    func mutate() {
        rememberUndo()
        push { $0.mutate() }
        refreshFromEngine()
    }

    func newSeed() {
        let s = UInt64.random(in: 1..<UInt64.max)
        applySeed(s)
    }

    func requestSurprise() {
        push { $0.interest.request() }
    }

    func queueCue(_ kind: ArrangementCueKind) {
        rememberUndo()
        // The scheduler already owns up to one lookahead bar. Queue beyond
        // that horizon, then quantize upward to a four-bar phrase boundary.
        let earliest = max(snapshot.bar + 1, playhead.bar + 2)
        let start = ((earliest + 3) / 4) * 4
        push { $0.queueCue(kind, startBar: start, currentBar: self.snapshot.bar) }
        statusMessage = "\(kind.rawValue) queued for bar \(start + 1)"
    }

    func clearQueuedCues() {
        rememberUndo()
        push { $0.clearFutureCues(after: self.snapshot.bar) }
        statusMessage = "cleared future cues"
    }

    func panic() {
        scheduler.panic()
    }

    func toggleMute(_ voice: Voice) {
        let value = !(muted[voice] ?? false)
        muted[voice] = value
        push { $0.muted[voice] = value }
    }

    func toggleSolo(_ voice: Voice) {
        soloed = soloed == voice ? nil : voice
        let selected = soloed
        push { $0.soloed = selected }
    }

    func audition(_ voice: Voice) {
        let port = MIDIOut.Port(voice: voice)
        let note: Int
        switch voice {
        case .drums: note = 36
        case .bass: note = 36 + key
        case .chords: note = 48 + key
        case .melody: note = 60 + key
        case .drone: note = 36 + key
        case .pulse: note = 72 + key
        }
        midi.noteOn(port: port, note: note, velocity: 84, hostTime: 0)
        monitor.audition(voice, note: note)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.midi.noteOff(port: port, note: note, hostTime: 0)
        }
    }

    func applySeed(_ s: UInt64) {
        rememberUndo()
        seed = s
        push { $0.reseed(s) }
        refreshFromEngine()
    }

    /// Pull params back from the engine after mutate/reseed so knobs jump to
    /// their new positions.
    private func refreshFromEngine() {
        scheduler.withEngine { engine in
            let params = engine.params
            let s = engine.masterSeed
            let homeKey = engine.harmonyEngine.key
            let homeScale = engine.harmonyEngine.scale
            DispatchQueue.main.async {
                for v in Voice.allCases { self.baseParams[v] = params[v]?.values ?? [:] }
                self.seed = s
                // A reseed rolls a new home key/scale; mirror it so the key/scale
                // selectors reflect the new piece rather than the old home.
                self.key = homeKey
                self.scaleChoice = homeScale
            }
        }
    }

    // MARK: performance memory

    func captureState(name: String = "loom performance") -> PerformanceState {
        func doubles(_ source: [Voice: Double]) -> [String: Double] {
            Dictionary(uniqueKeysWithValues: Voice.allCases.map { ($0.rawValue, source[$0] ?? 0.5) })
        }
        func bools(_ source: [Voice: Bool]) -> [String: Bool] {
            Dictionary(uniqueKeysWithValues: Voice.allCases.map { ($0.rawValue, source[$0] ?? false) })
        }
        return PerformanceState(
            compositionModel: snapshotCompositionVersion(),
            name: name, seed: seed, tempo: tempo, key: key, scale: scaleChoice,
            params: Dictionary(uniqueKeysWithValues: Voice.allCases.map {
                ($0.rawValue, baseParams[$0] ?? Defaults.params(for: $0).values)
            }),
            drift: doubles(drift), locked: bools(locked), muted: bools(muted),
            evolutionRate: evolutionRate, motifRecurrence: motifRecurrence,
            sectionLength: sectionLength, link: link, wander: wander,
            grit: grit, push: performancePush,
            grooveStyle: grooveStyle, harmonyDialect: harmonyDialect,
            arrangementCues: snapshotCues(), clockMode: clockMode,
            transitions: transitions)
    }

    private func snapshotCues() -> [ArrangementCue] {
        var cues: [ArrangementCue] = []
        scheduler.withEngine { cues = $0.evolution.arrangementCues }
        return cues
    }

    private func snapshotCompositionVersion() -> CompositionModelVersion {
        var version = CompositionModelVersion.persistentThemes
        scheduler.withEngine { version = $0.compositionVersion }
        return version
    }

    func captureA() {
        slotA = captureState(name: "A")
        statusMessage = "captured A"
    }

    func captureB() {
        slotB = captureState(name: "B")
        statusMessage = "captured B"
    }

    func recallA() { if let slotA { recall(slotA) } }
    func recallB() { if let slotB { recall(slotB) } }

    private func recall(_ state: PerformanceState) {
        rememberUndo()
        restore(state, includeIdentity: true)
        statusMessage = "recalled \(state.name)"
    }

    func morphToB(bars: Int = 8) {
        guard let slotB else { statusMessage = "capture B first"; return }
        rememberUndo()
        activeMorph = ActiveMorph(from: captureState(name: "morph start"), to: slotB,
                                  startBar: snapshot.bar, bars: max(1, bars))
        morphProgress = 0
        statusMessage = "morphing to B over \(max(1, bars)) bars"
    }

    private func advanceMorph(at bar: Int) {
        guard let activeMorph else { return }
        let t = min(1, max(0, Double(bar - activeMorph.startBar) / Double(activeMorph.bars)))
        applyContinuous(activeMorph.from.morphed(toward: activeMorph.to, amount: t))
        morphProgress = t
        if t >= 1 {
            self.activeMorph = nil
            morphProgress = nil
            statusMessage = "morph complete"
        }
    }

    func undo() {
        guard let state = undoStack.popLast() else { return }
        restore(state, includeIdentity: true)
        canUndo = !undoStack.isEmpty
        statusMessage = "undid last performance change"
    }

    private func rememberUndo() {
        undoStack.append(captureState(name: "undo"))
        if undoStack.count > 20 { undoStack.removeFirst(undoStack.count - 20) }
        canUndo = true
    }

    private func restore(_ state: PerformanceState, includeIdentity: Bool) {
        activeMorph = nil
        morphProgress = nil
        let resume = playing
        if resume { scheduler.stop() }
        scheduler.withEngine { state.apply(to: $0, includeIdentity: includeIdentity) }
        if includeIdentity {
            scheduler.rewind()
            seed = state.seed
            key = state.key
            scaleChoice = state.scale
            roll.removeAll()
            rollGeneration += 1
            playhead.bar = 0
            playhead.phase = 0
        }
        publish(state)
        if resume { scheduler.play() }
    }

    private func applyContinuous(_ state: PerformanceState) {
        scheduler.withEngine { state.apply(to: $0, includeIdentity: false) }
        publish(state)
    }

    private func publish(_ state: PerformanceState) {
        tempo = state.tempo
        evolutionRate = state.evolutionRate
        motifRecurrence = state.motifRecurrence
        sectionLength = state.sectionLength
        link = state.link
        wander = state.wander
        grit = state.grit
        performancePush = state.push
        transitions = state.transitions ?? 0.5
        grooveStyle = state.grooveStyle
        harmonyDialect = state.harmonyDialect
        clockMode = state.clockMode ?? .internalClock
        for voice in Voice.allCases {
            baseParams[voice] = state.migratedParams(for: voice)
            drift[voice] = state.value(state.drift, for: voice, default: 0.5)
            locked[voice] = state.value(state.locked, for: voice, default: false)
            muted[voice] = state.value(state.muted, for: voice, default: false)
        }
        soloed = nil
    }

    // MARK: files

    func savePerformance() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "loom-\(String(seed, radix: 16)).loom.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(captureState()).write(to: url, options: .atomic)
            statusMessage = "saved \(url.lastPathComponent)"
        } catch {
            statusMessage = "save failed: \(error.localizedDescription)"
        }
    }

    func loadPerformance() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let state = try JSONDecoder().decode(PerformanceState.self, from: Data(contentsOf: url))
            rememberUndo()
            restore(state, includeIdentity: true)
            statusMessage = "loaded \(url.lastPathComponent)"
        } catch {
            statusMessage = "load failed: \(error.localizedDescription)"
        }
    }

    func exportMIDI(bars: Int = 128) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.midi]
        panel.nameFieldStringValue = "loom-\(String(seed, radix: 16))-\(bars)-bars.mid"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let state = captureState()
        statusMessage = "rendering \(bars) bars…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let data = MIDIFileExporter.render(state, bars: bars)
            do {
                try data.write(to: url, options: .atomic)
                DispatchQueue.main.async { self?.statusMessage = "exported \(url.lastPathComponent)" }
            } catch {
                DispatchQueue.main.async { self?.statusMessage = "export failed: \(error.localizedDescription)" }
            }
        }
    }

    // MARK: bindings

    func paramBinding(_ voice: Voice, _ name: String) -> Binding<Double> {
        Binding(
            get: { self.baseParams[voice]?[name] ?? 0.5 },
            set: { value in
                self.baseParams[voice]?[name] = value
                self.push { $0.params[voice]?[name] = value }
            }
        )
    }

    func driftBinding(_ voice: Voice) -> Binding<Double> {
        Binding(
            get: { self.drift[voice] ?? 0.5 },
            set: { value in
                self.drift[voice] = value
                self.push { $0.evolution.drift[voice] = value }
            }
        )
    }

    func lockBinding(_ voice: Voice) -> Binding<Bool> {
        Binding(
            get: { self.locked[voice] ?? false },
            set: { value in
                self.locked[voice] = value
                self.push { $0.evolution.locked[voice] = value }
            }
        )
    }

    func effectiveValue(_ voice: Voice, _ name: String) -> Double? {
        snapshot.effectiveParams[voice]?[name]
    }

}
