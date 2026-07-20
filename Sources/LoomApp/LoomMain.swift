import Foundation
import SwiftUI
import LoomCore

/// Headless check mode: `swift run LoomApp --check` generates a few bars and
/// verifies determinism and phrase-aligned harmony without opening a window
/// (useful over SSH/CI).
func runHeadlessCheck() -> Never {
    let bars = 32
    func render(_ seed: UInt64) -> (lines: [String], snaps: [EngineSnapshot], events: [[NoteEvent]]) {
        let e = Engine(seed: seed)
        e.rewind()
        var lines: [String] = []
        var snaps: [EngineSnapshot] = []
        var events: [[NoteEvent]] = []
        for bar in 0..<bars {
            let out = e.generateBar(bar)
            let snap = out.snapshot
            let counts = Voice.allCases.map { v in "\(v.rawValue):\(out.events.filter { $0.voice == v }.count)" }
            lines.append("bar \(bar)  [\(snap.section.rawValue) t=\(String(format: "%.2f", snap.tension))]  "
                + "phrase \(snap.phraseLabel) \(snap.phraseBar + 1)/\(snap.phraseBars)  chord \(snap.chordLabel)"
                + (snap.isChordChangeBar ? "*" : " ") + "  "
                + counts.joined(separator: " ") + "  cc:\(out.controls.count)")
            snaps.append(snap)
            events.append(out.events)
        }
        return (lines, snaps, events)
    }
    let a = render(0xBEEF)
    let b = render(0xBEEF)
    print(a.lines.joined(separator: "\n"))

    var ok = true
    if a.lines != b.lines {
        print("\ndeterminism: FAILED"); ok = false
    } else {
        print("\ndeterminism: OK (seed 0xBEEF reproduces identically)")
    }
    // Chord changes must land on chord-change bars only.
    var aligned = true
    for i in 1..<a.snaps.count where a.snaps[i].chordLabel != a.snaps[i - 1].chordLabel {
        if !a.snaps[i].isChordChangeBar { aligned = false }
    }
    print(aligned ? "harmonic rhythm: OK (chord changes bar-aligned)"
                  : "harmonic rhythm: FAILED (chord changed off a change bar)")
    ok = ok && aligned

    // Drone spans: notes only on span-start bars, held in whole bars.
    var droneOK = true
    for barEvents in a.events {
        for ev in barEvents where ev.voice == .drone {
            if ev.startStep != 0 { droneOK = false }
            let barsHeld = (ev.durationSteps + 1) / Double(stepsPerBar)
            if barsHeld.rounded() != barsHeld || barsHeld < 1 || barsHeld > 16 { droneOK = false }
        }
    }
    let droneBars = a.events.filter { be in be.contains { $0.voice == .drone } }.count
    print(droneOK && droneBars > 0
          ? "drone spans: OK (\(droneBars) span starts in \(bars) bars, whole-bar holds ≤ 16)"
          : "drone spans: FAILED")
    ok = ok && droneOK && droneBars > 0

    // Pool law: 5–7 pitch classes, tonic and its 5th always present.
    let home = Engine(seed: 0xBEEF).harmonyEngine
    let tonic = ((home.key % 12) + 12) % 12
    let fifth = (tonic + 7) % 12
    var poolOK = true
    for snap in a.snaps {
        if !(5...7).contains(snap.pool.count) { poolOK = false }
        if !snap.pool.contains(tonic) || !snap.pool.contains(fifth) { poolOK = false }
    }
    print(poolOK ? "pitch pool: OK (5–7 pcs, tonic + 5th present)"
                 : "pitch pool: FAILED")
    ok = ok && poolOK

    // Low-tension sparseness: quiet bars stay quiet. Drums are judged by
    // their continuous presence envelope, not tension — a fading kit tail
    // in a low-tension bar is the blend working as designed.
    let quiet = zip(a.snaps, a.events).filter { $0.0.tension < 0.3 }
    if !quiet.isEmpty {
        let counts = quiet.map { $0.1.filter { $0.voice != .drone && $0.voice != .drums }.count }
        let mean = Double(counts.reduce(0, +)) / Double(counts.count)
        var drumsOK = true
        for (snap, evs) in quiet where snap.drumPresence < 0.2 {
            let drums = evs.filter { $0.voice == .drums }
            if drums.count > 3 || drums.contains(where: {
                $0.note == DrumTrack.kick.note || $0.note == DrumTrack.snare.note
            }) {
                drumsOK = false
            }
        }
        let sparse = mean <= 6.0 && drumsOK
        print(sparse ? String(format: "sparseness: OK (mean %.1f pitched events/bar below tension 0.3, kit lawful)", mean)
                     : String(format: "sparseness: FAILED (mean %.1f pitched events/bar%@)", mean,
                              drumsOK ? "" : ", kit unlawful at low presence"))
        ok = ok && sparse
    }

    // Key journey: opens at home, wanders to related keys, returns home.
    let je = Engine(seed: 0xBEEF)
    let sb = je.evolution.sectionBars
    let tAt: (Int) -> Double = { je.conductor.state(bar: $0, sectionBars: sb).tension }
    var regions: [JourneyRegion] = []
    for b in stride(from: 0, to: 600, by: 4) {
        let r = je.harmonyEngine.journeyRegion(atBar: b, tensionAt: tAt)
        if r.index != regions.last?.index { regions.append(r) }
    }
    var journeyOK = regions.first?.key == je.harmonyEngine.key
        && regions.first?.scale == je.harmonyEngine.scale
    var away = 0
    for r in regions {
        if r.key == je.harmonyEngine.key && r.scale == je.harmonyEngine.scale { away = 0 }
        else { away += 1; if away > 3 { journeyOK = false } }
    }
    let keys = regions.map { "\(noteNames[$0.key]) \($0.scale.rawValue)" }.joined(separator: " → ")
    print(journeyOK ? "key journey: OK (\(keys))" : "key journey: FAILED (\(keys))")
    ok = ok && journeyOK

    // Arrangement events: build → vacuum closes a develop, the drop opens
    // its peak, and exhale opens a post-peak breakdown.
    var eventsOK = true
    var eventCount = 0
    for b in 0..<600 {
        let s = je.conductor.state(bar: b, sectionBars: sb)
        switch s.event {
        case .build:
            eventCount += 1
            let bBars = je.conductor.buildBars(len: s.sectionLength)
            if s.section != .develop || s.sectionBar < s.sectionLength - 1 - bBars
                || s.sectionBar >= s.sectionLength - 1 { eventsOK = false }
        case .vacuum:
            eventCount += 1
            if s.section != .develop || s.sectionBar != s.sectionLength - 1 { eventsOK = false }
        case .drop:
            eventCount += 1
            if s.section != .peak || s.sectionBar != 0 { eventsOK = false }
        case .exhale:
            eventCount += 1
            if s.section != .breakdown || s.sectionBar >= je.conductor.exhaleBars() { eventsOK = false }
        case nil: break
        }
    }
    print(eventsOK ? "arrangement events: OK (\(eventCount) in 600 bars, all lawful)"
                   : "arrangement events: FAILED")
    ok = ok && eventsOK

    // A saved performance must survive JSON exactly enough to regenerate its
    // controls, and the DAW export must be tempo + six musical tracks.
    let artifactEngine = Engine(seed: 0x1234_5678_9ABC_DEF0)
    var artifactState = PerformanceState(
        name: "headless check",
        seed: artifactEngine.masterSeed,
        tempo: artifactEngine.tempo,
        key: artifactEngine.harmonyEngine.key,
        scale: artifactEngine.harmonyEngine.scale,
        params: Dictionary(uniqueKeysWithValues: Voice.allCases.map {
            ($0.rawValue, artifactEngine.params[$0]?.values ?? [:])
        }),
        drift: Dictionary(uniqueKeysWithValues: Voice.allCases.map {
            ($0.rawValue, artifactEngine.evolution.drift[$0] ?? 0.5)
        }),
        locked: Dictionary(uniqueKeysWithValues: Voice.allCases.map {
            ($0.rawValue, artifactEngine.evolution.locked[$0] ?? false)
        }),
        muted: Dictionary(uniqueKeysWithValues: Voice.allCases.map { ($0.rawValue, false) }),
        evolutionRate: artifactEngine.evolution.evolutionRate,
        motifRecurrence: artifactEngine.evolution.motifRecurrence,
        sectionLength: artifactEngine.evolution.sectionLength,
        link: artifactEngine.evolution.link,
        wander: artifactEngine.evolution.wander,
        grit: artifactEngine.evolution.grit,
        push: artifactEngine.evolution.push,
        grooveStyle: .halftime,
        harmonyDialect: .ambient,
        arrangementCues: [ArrangementCue(startBar: 4, kind: .buildDrop)],
        clockMode: .externalClock
    )
    // Exercise values that differ from the engine defaults.
    artifactState.grit = 0.42
    artifactState.muted[Voice.drums.rawValue] = true
    do {
        let encoded = try JSONEncoder().encode(artifactState)
        let decoded = try JSONDecoder().decode(PerformanceState.self, from: encoded)
        let identityOK = decoded.seed == artifactState.seed
        let parametersOK = decoded.params == artifactState.params
        let gritOK = decoded.grit == artifactState.grit
        let mutesOK = decoded.muted == artifactState.muted
        let directionOK = decoded.grooveStyle == .halftime
            && decoded.harmonyDialect == .ambient
            && decoded.arrangementCues == [ArrangementCue(startBar: 4, kind: .buildDrop)]
            && decoded.clockMode == .externalClock
        // Simulate a version-1 file by removing every added top-level key.
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacy["version"] = 1
        for key in ["grooveStyle", "harmonyDialect", "arrangementCues", "clockMode"] {
            legacy.removeValue(forKey: key)
        }
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        let legacyState = try JSONDecoder().decode(PerformanceState.self, from: legacyData)
        let legacyOK = legacyState.grooveStyle == nil
            && legacyState.harmonyDialect == nil
            && legacyState.arrangementCues == nil
            && legacyState.clockMode == nil

        // Version-2 register migration: the former coarse octave + fine
        // register pair becomes one truthful continuous control, and retired
        // parameters do not leak back into the engine.
        var v2 = artifactState
        v2.version = 2
        v2.params[Voice.chords.rawValue] = [
            "amount": 0.46, "voicing": 0.42, "octave": 0.5,
            "spread": 0.62, "length": 0.72, "vary": 0.35,
            "extensions": 0.12, "humanize": 0.40,
        ]
        v2.params[Voice.melody.rawValue] = [
            "amount": 0.34, "density": 0.28, "rest": 0.68,
            "octave": 0.5, "range": 0.46, "length": 0.52,
            "vary": 0.35, "dynamics": 0.62, "motion": 0.42,
            "repeat": 0.56, "contour": 0.38, "glide": 0.2,
            "humanize": 0.42,
        ]
        let migrated = try JSONDecoder().decode(
            PerformanceState.self, from: JSONEncoder().encode(v2)).makeEngine()
        let migrationOK = migrated.params[.chords]?.values["register"] != nil
            && migrated.params[.chords]?.values["length"] == nil
            && migrated.params[.melody]?.values["register"] != nil
            && migrated.params[.melody]?.values["octave"] == nil
        let persistenceOK = identityOK && parametersOK && gritOK && mutesOK
            && directionOK && legacyOK && migrationOK
        print(persistenceOK ? "performance file: OK (JSON round-trip)"
                            : "performance file: FAILED (round-trip mismatch)")
        ok = ok && persistenceOK

        let midi = MIDIFileExporter.render(decoded, bars: 8)
        let bytes = [UInt8](midi)
        let marker = Array("MTrk".utf8)
        let tracks = bytes.indices.reduce(into: 0) { count, index in
            guard index + marker.count <= bytes.count else { return }
            if Array(bytes[index..<(index + marker.count)]) == marker { count += 1 }
        }
        let headerOK = bytes.starts(with: Array("MThd".utf8))
        let tracksOK = tracks == 7
        let sizeOK = midi.count > 100
        let midiOK = headerOK && tracksOK && sizeOK
        print(midiOK ? "MIDI export: OK (format 1, \(tracks) tracks, \(midi.count) bytes)"
                     : "MIDI export: FAILED (header \(headerOK), tracks \(tracks), bytes \(midi.count))")
        ok = ok && midiOK
    } catch {
        print("performance file / MIDI export: FAILED (\(error))")
        ok = false
    }

    // UI contract: every active parameter has exactly one audited control,
    // every control teaches more than its value, and voice colors are
    // materially distinct before the app opens a window.
    var controlsOK = true
    for voice in Voice.allCases {
        let specs = ControlCatalog.controls(for: voice)
        controlsOK = controlsOK
            && Set(specs.map(\.name)) == Set(Defaults.params(for: voice).names)
            && Set(specs.map(\.name)).count == specs.count
            && specs.allSatisfy { !$0.summary.isEmpty && !$0.context.isEmpty }
    }
    var colorsOK = true
    for (i, a) in uiVoiceOrder.enumerated() {
        let x = Theme.voiceRGB(a)
        for b in uiVoiceOrder.dropFirst(i + 1) {
            let y = Theme.voiceRGB(b)
            let distance = sqrt(pow(x.0 - y.0, 2) + pow(x.1 - y.1, 2) + pow(x.2 - y.2, 2))
            if distance < 0.28 { colorsOK = false }
        }
    }
    print(controlsOK && colorsOK
          ? "control surface: OK (all parameters audited, six separated colors)"
          : "control surface: FAILED")
    ok = ok && controlsOK && colorsOK
    exit(ok ? 0 : 1)
}

@main
struct LoomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    init() {
        if CommandLine.arguments.contains("--check") {
            runHeadlessCheck()
        }
    }

    var body: some Scene {
        WindowGroup("loom") {
            ContentView(model: model)
        }
        .defaultSize(width: 1180, height: 860)
        .windowResizability(.contentSize)
    }
}

/// Running from `swift run` gives no app bundle; promote ourselves to a
/// regular foreground app so the window appears and takes focus.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // A restored frame from an earlier (taller) build can leave the
        // window under the menu bar or dock — clamp every window into the
        // screen's visible area once the scene has built it.
        DispatchQueue.main.async {
            for window in NSApp.windows {
                guard let screen = window.screen ?? NSScreen.main else { continue }
                let vis = screen.visibleFrame
                var f = window.frame
                f.size.width = min(f.width, vis.width)
                f.size.height = min(f.height, vis.height)
                f.origin.x = max(vis.minX, min(f.origin.x, vis.maxX - f.width))
                f.origin.y = max(vis.minY, min(f.origin.y, vis.maxY - f.height))
                if f != window.frame { window.setFrame(f, display: true) }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
