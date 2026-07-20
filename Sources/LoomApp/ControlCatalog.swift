import SwiftUI
import LoomCore

struct ControlChoice: Identifiable, Hashable {
    let label: String
    let value: Double
    var id: String { "\(label)-\(value)" }
}

enum ParamControlKind {
    case continuous(low: String, high: String)
    case choices([ControlChoice])
}

struct ParamControlSpec: Identifiable {
    let voice: Voice
    let name: String
    let label: String
    let kind: ParamControlKind
    let summary: String
    let context: String
    var id: String { "\(voice.rawValue).\(name)" }

    var defaultValue: Double { Defaults.params(for: voice)[name] }

    func display(_ value: Double) -> String {
        switch name {
        case "amount":
            return value < 0.4 ? "held back" : (value > 0.6 ? "forward" : "auto")
        case "register":
            let note: Int
            switch voice {
            case .drone: note = 24 + Int((value * 16).rounded())
            case .chords: note = 48 + Int((value * 24).rounded())
            case .melody: note = 52 + Int((value * 30).rounded())
            default: note = 60
            }
            return "\(noteNames[((note % 12) + 12) % 12])\(note / 12 - 1)"
        case "length":
            return String(format: "%.2f×", lengthScale(value))
        case "swing", "density", "ghost", "gate":
            return "\(Int((value * 100).rounded()))%"
        default:
            if case .choices(let choices) = kind {
                return choices.min(by: { abs($0.value - value) < abs($1.value - value) })?.label ?? "—"
            }
            return String(format: "%.2f", value)
        }
    }

    func tip(base: Double, live: Double?) -> TipContent {
        let liveText = live.map { display($0) } ?? display(base)
        let rangeText: String
        switch kind {
        case .continuous(let low, let high): rangeText = "\(low)  →  \(high)"
        case .choices(let choices): rangeText = choices.map(\.label).joined(separator: " · ")
        }
        return TipContent(
            title: "\(voice.rawValue) · \(label)", summary: summary,
            range: rangeText,
            values: "set \(display(base)) · live \(liveText) · default \(display(defaultValue))",
            context: context)
    }
}

enum ControlCatalog {
    static let freshLoop = [
        ControlChoice(label: "fresh", value: 0.10),
        ControlChoice(label: "déjà-vu", value: 0.60),
        ControlChoice(label: "loop", value: 0.95),
    ]
    static let dynamics = [
        ControlChoice(label: "flat", value: 0.25),
        ControlChoice(label: "natural", value: 0.65),
        ControlChoice(label: "wide", value: 1.0),
    ]
    static let humanize = [
        ControlChoice(label: "tight", value: 0),
        ControlChoice(label: "human", value: 0.40),
        ControlChoice(label: "loose", value: 0.80),
    ]
    static let octave = [
        ControlChoice(label: "−1", value: 0),
        ControlChoice(label: "0", value: 0.5),
        ControlChoice(label: "+1", value: 1),
    ]

    static func controls(for voice: Voice) -> [ParamControlSpec] {
        switch voice {
        case .drone:
            return [
                c(voice, "register", "register", .continuous(low: "sub", high: "low-mid"),
                  "Moves the foundation through its safe low register.", "Applied at the next drone-span attack."),
                c(voice, "fifth", "fifth", .choices(onOff),
                  "Adds the fifth above the root for harmonic weight.", "A true layer switch; it is not modulated."),
                c(voice, "width", "octave", .choices(onOff),
                  "Adds the root an octave above for a wider foundation.", "A true layer switch; it is not modulated."),
                c(voice, "swell", "swell", .continuous(low: "still", high: "deep CC24"),
                  "Sets the depth of the slow CC24 triangle over each drone span.", "Map CC24 to filter, timbre, or send level in Ableton."),
            ]

        case .drums:
            return [
                presence(voice, "Biases when the kit enters and how fully it remains present."),
                c(voice, "density", "density", .continuous(low: "backbone", high: "decorated"),
                  "Adds optional kit detail around the dependable kick, snare, and hat grammar.", "The conductor still scales density with kit presence."),
                c(voice, "swing", "swing", .continuous(low: "straight", high: "late offbeats"),
                  "Delays off-eighths without moving the structural backbeat.", "Half-time adds a small style-specific swing bias."),
                c(voice, "ghost", "ghosts", .continuous(low: "clean", high: "answered"),
                  "Introduces quiet side-stick and snare answers around the backbone.", "Ghosts remain subordinate to the main snare."),
                c(voice, "ratchet", "ratchets", .choices([
                    .init(label: "off", value: 0), .init(label: "controlled", value: 0.20), .init(label: "busy", value: 0.65)]),
                  "Chooses how readily hats or snares fracture near fills.", "At most one controlled roll is favored over random retriggering."),
                c(voice, "fills", "fills", .choices([
                    .init(label: "rare", value: 0.20), .init(label: "phrase", value: 0.60), .init(label: "busy", value: 0.90)]),
                  "Sets how complete phrase-end fill gestures become.", "Fills remain tied to structural boundaries."),
                c(voice, "poly", "polymeter", .choices([
                    .init(label: "off", value: 0), .init(label: "subtle", value: 0.78), .init(label: "full", value: 1)]),
                  "Lets only side-stick and tom ornaments phase against 4/4.", "Kick, snare, and hats always retain the standard bar grid."),
                c(voice, "recur", "memory", .choices(freshLoop),
                  "Controls how often the learned two-, four-, or eight-bar kit cell returns.", "Structural hits remain lawful in every setting."),
                c(voice, "dynamics", "dynamics", .choices(dynamics),
                  "Sets the depth of metric accents, crescendos, and drop impact.", "This changes velocity shape, not MIDI track volume."),
                c(voice, "humanize", "feel", .choices(humanize),
                  "Adds correlated micro-timing and velocity movement.", "The backbone stays within a safe timing window."),
            ]

        case .bass:
            return [
                presence(voice, "Biases when the bass joins the conductor's low-end plan."),
                c(voice, "density", "density", .continuous(low: "roots", high: "moving line"),
                  "Chooses how many shared ensemble anchors become bass notes.", "Below medium tension the bass deliberately states only chord changes."),
                c(voice, "octave", "octave", .choices(octave),
                  "Places the bass line one of three whole-octave registers.", "The drone-clearance pass may lift a clashing low note."),
                c(voice, "follow", "pitch law", .choices([
                    .init(label: "scale", value: 0.05), .init(label: "mixed", value: 0.55), .init(label: "chord", value: 0.95)]),
                  "Balances scalar walking against chord-tone gravity.", "Downbeats on chord changes remain roots."),
                c(voice, "approach", "approach", .choices([
                    .init(label: "off", value: 0), .init(label: "subtle", value: 0.30), .init(label: "often", value: 0.75)]),
                  "Adds a lawful walk-in note before the next chord root.", "Only the final late-bar onset can become an approach."),
                c(voice, "accent", "accent", .choices([
                    .init(label: "even", value: 0.20), .init(label: "grooved", value: 0.62), .init(label: "punchy", value: 0.90)]),
                  "Controls the probability and strength of beat accents.", "Phrase dynamics continue to shape the whole line."),
                c(voice, "glide", "glide", .choices([
                    .init(label: "off", value: 0), .init(label: "sometimes", value: 0.30), .init(label: "legato", value: 0.90)]),
                  "Chooses how often notes overlap and emit portamento controls.", "The receiving Ableton instrument must honor glide/CC65."),
                c(voice, "recur", "memory", .choices(freshLoop),
                  "Controls rhythmic déjà-vu while repitching the line to current harmony.", "It never pastes obsolete pitches across a chord change."),
            ]

        case .chords:
            return [
                presence(voice, "Biases when the pad enters; it does not act as MIDI volume."),
                c(voice, "register", "register", .continuous(low: "low bed", high: "high veil"),
                  "Moves the voice-led pad through one useful continuous register.", "Rub avoidance may lift individual notes to clear ringing material."),
                c(voice, "spread", "voicing", .choices([
                    .init(label: "close", value: 0), .init(label: "open", value: 1)]),
                  "Switches between compact voicings and an open drop-2 shape.", "Common tones remain tied through chord changes."),
                c(voice, "humanize", "strum", .choices([
                    .init(label: "tight", value: 0), .init(label: "soft", value: 0.40), .init(label: "loose", value: 0.75)]),
                  "Sets the small upper-voice arrival spread of each pad attack.", "The pad attacks only on chord changes and long-chord re-swells."),
            ]

        case .pulse:
            return [
                presence(voice, "Biases when chord-locked rhythmic motion joins the form."),
                c(voice, "density", "density", .continuous(low: "punctuation", high: "persistent"),
                  "Controls how many slots survive in the learned pulse cell.", "The conductor suppresses it in vacuums and exhales."),
                c(voice, "division", "division", .choices([
                    .init(label: "1/4", value: 0), .init(label: "1/8", value: 0.5), .init(label: "1/16", value: 1)]),
                  "Selects the pulse's metric subdivision.", "Builds can temporarily accelerate the effective division."),
                c(voice, "gate", "gate", .continuous(low: "ticks", high: "connected"),
                  "Changes pulse note length without changing its pitch cell.", "The next subdivision still caps every note safely."),
                c(voice, "octave", "octave", .choices(octave),
                  "Places the chord tone in one of three registers.", "The pulse remains monophonic and chord-locked."),
                c(voice, "recur", "memory", .choices(freshLoop),
                  "Controls how strongly the two- or four-bar rhythmic cell repeats.", "Pitch is always realized against today's chord."),
                c(voice, "ratchet", "fracture", .choices([
                    .init(label: "off", value: 0), .init(label: "controlled", value: 0.20), .init(label: "busy", value: 0.65)]),
                  "Adds at most one compact repeated attack to a bar.", "Grit raises the chance without adding new pitches."),
                c(voice, "dynamics", "dynamics", .choices(dynamics),
                  "Sets metric accent depth and the weight of a drop landing.", "This shapes note velocity, not MIDI track volume."),
                c(voice, "humanize", "feel", .choices(humanize),
                  "Adds restrained timing and velocity movement to the cell.", "Its feel remains correlated with the ensemble groove."),
            ]

        case .melody:
            return [
                presence(voice, "Biases when the line is eligible to speak."),
                c(voice, "density", "note rate", .continuous(low: "few notes", high: "full gesture"),
                  "Sets the maximum notes and rhythmic granularity inside motif bars.", "It does not remove the melody's whole-bar rests."),
                c(voice, "rest", "space", .continuous(low: "speaks", high: "withholds"),
                  "Creates whole-bar rests, gaps, and a thinner phase loop.", "High values intentionally let harmony and pulse lead."),
                c(voice, "register", "register", .continuous(low: "near the pad", high: "high line"),
                  "Moves both motif and loop material through one coherent register control.", "Sustained notes are still kept above the pad."),
                c(voice, "length", "length", .continuous(low: "detached", high: "held"),
                  "Scales note duration while respecting chord boundaries.", "Passing tones remain short even at the high end."),
                c(voice, "dynamics", "dynamics", .choices(dynamics),
                  "Sets metric, phrase-arc, peak-note, and cadence contrast.", "Cadential resolutions remain gentler than peaks."),
                c(voice, "motion", "motion", .choices([
                    .init(label: "step", value: 0.20), .init(label: "mixed", value: 0.50), .init(label: "leap", value: 0.80)]),
                  "Balances stepwise movement against recoverable leaps.", "Every leap is followed by a step back toward balance."),
                c(voice, "repeat", "repetition", .choices([
                    .init(label: "varied", value: 0.20), .init(label: "mixed", value: 0.56), .init(label: "repeated", value: 0.85)]),
                  "Sets repeated-note likelihood inside a fresh motif cell.", "Motif recurrence is controlled separately at the global level."),
                c(voice, "contour", "contour", .choices([
                    .init(label: "fall", value: 0), .init(label: "arch", value: 0.5), .init(label: "rise", value: 1)]),
                  "Selects the broad direction of freshly generated phrases.", "Recalled motifs can still be transformed."),
                c(voice, "glide", "glide", .choices([
                    .init(label: "off", value: 0), .init(label: "sometimes", value: 0.20), .init(label: "legato", value: 0.90)]),
                  "Chooses how often notes request portamento in the receiving synth.", "The output uses overlap plus CC65/CC5."),
                c(voice, "humanize", "feel", .choices(humanize),
                  "Adds correlated micro-timing and velocity movement.", "Chord gravity and phrase timing remain intact."),
            ]
        }
    }

    private static let onOff = [
        ControlChoice(label: "off", value: 0),
        ControlChoice(label: "on", value: 1),
    ]

    private static func presence(_ voice: Voice, _ summary: String) -> ParamControlSpec {
        c(voice, "amount", "presence", .continuous(low: "held back", high: "forward"),
          summary, "Center follows the autonomous conductor; mute remains absolute.")
    }

    private static func c(_ voice: Voice, _ name: String, _ label: String,
                          _ kind: ParamControlKind, _ summary: String,
                          _ context: String) -> ParamControlSpec {
        ParamControlSpec(voice: voice, name: name, label: label, kind: kind,
                         summary: summary, context: context)
    }
}

struct InspectorParamControl: View {
    @ObservedObject var model: AppModel
    let spec: ParamControlSpec

    var body: some View {
        let binding = model.paramBinding(spec.voice, spec.name)
        let base = binding.wrappedValue
        let live = model.effectiveValue(spec.voice, spec.name)
        switch spec.kind {
        case .continuous(let low, let high):
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(spec.label).font(Theme.monoSmall).foregroundColor(Theme.mid)
                    Spacer()
                    Text(spec.display(base)).font(Theme.monoSmall).foregroundColor(Theme.text)
                }
                ZStack(alignment: .leading) {
                    Slider(value: binding, in: 0...1)
                        .controlSize(.mini).tint(Theme.voiceColor(spec.voice))
                    if let live, abs(live - base) > 0.01 {
                        GeometryReader { geo in
                            Circle().fill(Theme.voiceColor(spec.voice).opacity(0.55))
                                .frame(width: 5, height: 5)
                                .position(x: 7 + CGFloat(live) * max(1, geo.size.width - 14),
                                          y: geo.size.height / 2)
                        }
                        .allowsHitTesting(false)
                    }
                }
                HStack {
                    Text(low); Spacer(); Text(high)
                }
                .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.dim)
            }
            .tip(spec.tip(base: base, live: live))

        case .choices(let choices):
            VStack(alignment: .leading, spacing: 3) {
                Text(spec.label).font(Theme.monoSmall).foregroundColor(Theme.mid)
                if choices.count == 2 {
                    Toggle(choices[1].label, isOn: Binding(
                        get: { abs(binding.wrappedValue - choices[1].value)
                            <= abs(binding.wrappedValue - choices[0].value) },
                        set: { binding.wrappedValue = $0 ? choices[1].value : choices[0].value }))
                        .toggleStyle(.switch).controlSize(.mini)
                        .tint(Theme.voiceColor(spec.voice))
                        .font(Theme.monoSmall)
                } else {
                    Picker("", selection: Binding(
                        get: { choices.min(by: { abs($0.value - binding.wrappedValue)
                            < abs($1.value - binding.wrappedValue) })?.value ?? choices[0].value },
                        set: { binding.wrappedValue = $0 })) {
                        ForEach(choices) { Text($0.label).tag($0.value) }
                    }
                    .labelsHidden().pickerStyle(.segmented).controlSize(.small)
                }
            }
            .tip(spec.tip(base: base, live: live))
        }
    }
}

struct SegmentedValueControl: View {
    let label: String
    @Binding var value: Double
    let choices: [ControlChoice]
    let tip: TipContent

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(Theme.monoSmall).foregroundColor(Theme.mid)
            Picker("", selection: Binding(
                get: { choices.min(by: { abs($0.value - value) < abs($1.value - value) })?.value
                    ?? choices[0].value },
                set: { value = $0 })) {
                ForEach(choices) { Text($0.label).tag($0.value) }
            }
            .labelsHidden().pickerStyle(.segmented).controlSize(.small)
        }
        .tip(tip)
    }
}
