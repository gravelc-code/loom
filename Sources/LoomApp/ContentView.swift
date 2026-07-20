import SwiftUI
import LoomCore

struct ContentView: View {
    @ObservedObject var model: AppModel
    @StateObject private var tips = TipCenter()
    @AppStorage("loom.onboarding.seen") private var onboardingSeen = false
    @State private var showingOnboarding = false
    @State private var selectedVoice: Voice = .drums
    @State private var showingField = false
    @State private var showingSeed = false
    @State private var presenting = false
    @State private var presentField = false

    var body: some View {
        VStack(spacing: 8) {
            header.frame(height: 44)
            performanceRack.frame(height: 226)
            voiceRack.frame(height: 88)
            workbench.frame(maxHeight: .infinity)
        }
        .padding(10)
        .frame(width: 1180, height: 720, alignment: .top)
        .background(Theme.surface)
        .coordinateSpace(name: tipSpace)
        .overlay {
            // The floating tooltip for controls outside the inspector. Wired
            // throughout via `.tip(...)` but previously never mounted, so hover
            // help had no presentation; a GeometryReader keeps it sized to the
            // surface (and correct once the window can resize).
            GeometryReader { geo in
                TipOverlay(center: tips, size: geo.size)
            }
            .allowsHitTesting(false)
        }
        .overlay { if presenting { presentOverlay } }
        .environmentObject(tips)
        .preferredColorScheme(.light)
        .onAppear { if !onboardingSeen { showingOnboarding = true } }
        .sheet(isPresented: $showingOnboarding) {
            OnboardingView(model: model) {
                onboardingSeen = true
                showingOnboarding = false
            }
        }
    }

    // MARK: - Present mode

    /// Fills the window with the hero orbit (or the reaction-diffusion field)
    /// on a dark ground, so loom's best visual is not boxed at 192pt. The
    /// orbit draws its own light plate, so it reads as a glowing mandala.
    private var presentOverlay: some View {
        let ground = Color(red: 0.055, green: 0.055, blue: 0.070)
        return ZStack {
            ground.ignoresSafeArea()
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Text(model.snapshot.chordLabel)
                        .font(Theme.monoBig).foregroundColor(Theme.accentBright)
                    Text("next \(model.snapshot.nextChordLabel)")
                        .font(Theme.mono).foregroundColor(.white.opacity(0.55))
                    Spacer()
                    Text("bar \(model.snapshot.bar + 1) · \(model.snapshot.section.rawValue) · \(String(format: "t %.2f", model.snapshot.tension))")
                        .font(Theme.mono).foregroundColor(.white.opacity(0.55))
                }
                GeometryReader { geo in
                    let side = max(120, min(geo.size.width, geo.size.height))
                    HStack {
                        Spacer(minLength: 0)
                        if presentField {
                            FieldView(field: model.field, isPlaying: { model.playing },
                                      barDuration: { model.barDuration })
                                .frame(width: side, height: side)
                        } else {
                            OrbitView(model: model, side: side)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                }
                HStack(spacing: 18) {
                    presentControl(model.playing ? "stop.fill" : "play.fill") { model.togglePlay() }
                    presentControl("backward.end.fill") { model.rewind() }
                    presentControl(presentField ? "circle.hexagongrid" : "waveform.path.ecg") {
                        withAnimation(.easeInOut(duration: 0.22)) { presentField.toggle() }
                    }
                    Spacer()
                    presentControl("xmark") {
                        withAnimation(.easeInOut(duration: 0.3)) { presenting = false }
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
            .padding(26)
        }
        .transition(.opacity)
    }

    private func presentControl(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.82))
                .frame(width: 40, height: 30)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(Color.white.opacity(0.08)))
        }.buttonStyle(.plain)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Text("loom").font(.system(size: 21, weight: .heavy, design: .monospaced))
                    .foregroundColor(Theme.text)
                Circle().fill(Theme.accent).frame(width: 7, height: 7).offset(y: 5)
            }

            transportButton(model.playing ? "stop.fill" : "play.fill", active: model.playing) {
                model.togglePlay()
            }
            .keyboardShortcut(.space, modifiers: [])
            .tip(TipContent(title: "transport", summary: "Start or stop Loom's scheduler.",
                            range: "space bar performs the same action",
                            context: model.clockMode == .externalClock
                                ? "Ableton owns start/stop in external-clock mode." : "Loom sends MIDI clock and transport."))
            transportButton("backward.end.fill", active: false) { model.rewind() }
                .tip("rewind to bar 1; the same seed reproduces the complete form")

            headerLabel("bpm") {
                if model.clockMode == .externalClock {
                    Text(String(format: "%.1f ext", model.tempo)).font(Theme.mono)
                        .foregroundColor(Theme.accent).frame(width: 57)
                } else {
                    DragNumber(value: $model.tempo, range: 50...180, format: "%.0f")
                }
            }
            headerLabel("key") {
                Picker("", selection: $model.key) {
                    ForEach(0..<12, id: \.self) { Text(noteNames[$0]).tag($0) }
                }.labelsHidden().frame(width: 54)
            }
            headerLabel("scale") {
                Picker("", selection: $model.scaleChoice) {
                    ForEach(Scale.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(width: 96)
            }

            heroKnob("push", value: $model.performancePush, reset: 0.5,
                     summary: "Moves the whole ensemble between withheld and forward without rewriting the form.",
                     range: "space  →  conductor  →  full")
            heroKnob("grit", value: $model.grit, reset: 0.45,
                     summary: "Adds harmonic bite, phrase fractures, and stronger structural intervention.",
                     range: "pure  →  colored  →  frayed")
            heroKnob("evolve", value: $model.evolutionRate, reset: 0.5,
                     summary: "Sets the speed of every slow modulation source; zero now genuinely freezes them.",
                     range: "still  →  breathing  →  fast drift")

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 1) {
                Text(model.snapshot.chordLabel).font(Theme.mono).foregroundColor(Theme.accent)
                Text("next \(model.snapshot.nextChordLabel) · \(model.snapshot.keyLabel)")
                    .font(Theme.monoSmall).foregroundColor(Theme.mid).lineLimit(1)
            }
            .tip(TipContent(title: "harmony", summary: "Sounding chord, next chord, and current journey key.",
                            context: "Every pitched voice receives this same harmonic context."))

            Button { model.monitorEnabled.toggle() } label: {
                Image(systemName: model.monitorEnabled ? "speaker.wave.2.fill" : "speaker.slash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(model.monitorEnabled ? Theme.accent : Theme.dim)
                    .frame(width: 26, height: 24)
            }.buttonStyle(.plain)
                .tip("toggle the dark reference monitor; MIDI output continues either way")

            Button { withAnimation(.easeInOut(duration: 0.3)) { presenting = true } } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.dim).frame(width: 26, height: 24)
            }.buttonStyle(.plain)
                .keyboardShortcut("f", modifiers: [])
                .tip("present: fill the window with the orbit on a dark ground (f)")

            Circle().fill(model.midi.available ? Color.green.opacity(0.75) : Color.red.opacity(0.75))
                .frame(width: 7, height: 7)
                .tip(model.midi.available ? "seven CoreMIDI outputs are online" : "CoreMIDI is unavailable")

            Button { showingSeed.toggle() } label: {
                Text(String(format: "%06llx", model.seed & 0xFF_FFFF))
                    .font(Theme.monoSmall).foregroundColor(Theme.text)
                    .padding(.horizontal, 6).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.well))
            }.buttonStyle(.plain)
                .popover(isPresented: $showingSeed) { seedPopover }
                .tip("the final six digits of the deterministic seed; click to edit all 64 bits")

            utilityMenu
            transportButton("exclamationmark.triangle", active: false) { model.panic() }
                .tip("panic: send all-notes-off and clear scheduled tails")
        }
        .padding(.horizontal, 3)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline.opacity(0.55)).frame(height: 1)
        }
    }

    private func heroKnob(_ label: String, value: Binding<Double>, reset: Double,
                          summary: String, range: String) -> some View {
        Knob(label: label, value: value, resetValue: reset, diameter: 29, controlWidth: 42,
             tipContent: TipContent(title: label, summary: summary, range: range,
                                    values: String(format: "set %.2f · default %.2f", value.wrappedValue, reset)))
    }

    private var seedPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("performance seed").font(Theme.bayTitle).foregroundColor(Theme.text)
            SeedEditor(model: model)
            HStack {
                Button("new") { model.newSeed() }
                Button("mutate") { model.mutate() }
                Button("undo") { model.undo() }.disabled(!model.canUndo)
            }.buttonStyle(.bordered)
        }
        .padding(14).background(Theme.surface)
    }

    private var utilityMenu: some View {
        Menu {
            Button("New seed") { model.newSeed() }
            Button("Mutate unlocked voices") { model.mutate() }
            Button("Undo") { model.undo() }.disabled(!model.canUndo)
            Divider()
            Button("Save performance…") { model.savePerformance() }
            Button("Load performance…") { model.loadPerformance() }
            Button("Export 128 bars as MIDI…") { model.exportMIDI() }
            Divider()
            Button("Set snapshot A") { model.captureA() }
            Button("Set snapshot B") { model.captureB() }
            Button("Recall A") { model.recallA() }.disabled(model.slotA == nil)
            Button("Recall B") { model.recallB() }.disabled(model.slotB == nil)
            Button("Morph to B") { model.morphToB() }.disabled(model.slotB == nil)
            Divider()
            Button("MIDI setup help…") { showingOnboarding = true }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 12, weight: .bold))
                .foregroundColor(Theme.text).frame(width: 28, height: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.well))
        }.menuStyle(.borderlessButton).frame(width: 30)
    }

    // MARK: - Performance

    private var performanceRack: some View {
        Rack {
            HStack(spacing: 0) {
                VStack(spacing: 3) {
                    HStack {
                        Text("orbit").font(Theme.bayTitle).foregroundColor(Theme.dim)
                        Spacer()
                        Text("bar \(model.snapshot.bar + 1)").font(Theme.monoSmall).foregroundColor(Theme.mid)
                    }
                    OrbitView(model: model, side: 192)
                }
                .padding(9).frame(width: 216)

                RackRule()

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text("\(model.snapshot.formProfile.rawValue) form")
                            .font(Theme.bayTitle).foregroundColor(Theme.text)
                        Text("\(model.snapshot.section.rawValue) \(model.snapshot.sectionBar + 1)/\(model.snapshot.sectionLength)")
                            .font(Theme.monoSmall).foregroundColor(Theme.mid)
                        Text(nextEventText).font(Theme.monoSmall).foregroundColor(Theme.accent)
                        Spacer()
                        Text(String(format: "tension %.2f", model.snapshot.tension))
                            .font(Theme.monoSmall).foregroundColor(Theme.mid)
                        if !model.snapshot.causalLabel.isEmpty {
                            Text("◆ \(model.snapshot.causalLabel)")
                                .font(Theme.monoSmall).foregroundColor(Theme.dim).lineLimit(1)
                        }
                    }
                    RollingFormStrip(snapshot: model.snapshot, playhead: model.playhead)
                        .frame(height: 57)
                    RollLegend(selected: $selectedVoice).frame(height: 20)
                    PerformancePianoRoll(model: model, playhead: model.playhead,
                                         selected: selectedVoice)
                        .frame(height: 100)
                    HStack(spacing: 7) {
                        Text("motif").font(Theme.monoSmall).foregroundColor(Theme.dim)
                        MotifStrip(snapshot: model.snapshot)
                        Text("\(model.snapshot.motifCellIDs.count)/8 cells")
                            .font(Theme.monoSmall).foregroundColor(Theme.mid)
                    }.frame(height: 14)
                }
                .padding(9)
            }
        }
    }

    private var nextEventText: String {
        if let item = model.snapshot.arrangementPreview.dropFirst().enumerated()
            .first(where: { $0.element.event != nil || $0.element.cue != nil }) {
            let label = item.element.cue?.rawValue ?? item.element.event?.rawValue ?? "event"
            return "next \(label) · \(item.offset + 1) bars"
        }
        return "32 bars clear"
    }

    // MARK: - Voices and inspector

    private var voiceRack: some View {
        HStack(spacing: 6) {
            ForEach(uiVoiceOrder, id: \.self) { voice in
                VoiceStrip(model: model, voice: voice, selected: $selectedVoice)
            }
        }
    }

    private var workbench: some View {
        Rack {
            HStack(alignment: .top, spacing: 0) {
                selectedVoiceInspector.frame(maxWidth: .infinity)
                RackRule()
                utilityWorkbench.frame(width: 430)
            }
        }
    }

    private var selectedVoiceInspector: some View {
        let specs = ControlCatalog.controls(for: selectedVoice)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.voiceColor(selectedVoice))
                    .frame(width: 8, height: 20)
                Text("\(selectedVoice.rawValue) detail").font(Theme.bayTitle).foregroundColor(Theme.text)
                Text(voiceSummary(selectedVoice)).font(Theme.monoSmall).foregroundColor(Theme.mid)
                    .lineLimit(1)
                Spacer()
                Text("drift").font(Theme.monoSmall).foregroundColor(Theme.dim)
                Picker("", selection: Binding(
                    get: { nearest(model.drift[selectedVoice] ?? 0.5, in: driftChoices) },
                    set: { model.driftBinding(selectedVoice).wrappedValue = $0 })) {
                    ForEach(driftChoices) { Text($0.label).tag($0.value) }
                }
                .labelsHidden().pickerStyle(.segmented).controlSize(.small).frame(width: 180)
                .tip(TipContent(title: "\(selectedVoice.rawValue) · drift",
                                summary: "Sets how far curated slow modulation may move this voice.",
                                range: "static · gentle · free",
                                values: "Lock also freezes the voice's seed; static drift does not."))
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                      alignment: .leading, spacing: 7) {
                ForEach(specs) { InspectorParamControl(model: model, spec: $0) }
            }
            Spacer(minLength: 0)
            ContextHelpBar()
                .padding(.horizontal, 7).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.well.opacity(0.55)))
        }
        .padding(10)
    }

    private var utilityWorkbench: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(showingField ? "modulation field" : "direction + form")
                    .font(Theme.bayTitle).foregroundColor(Theme.text)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.26)) { showingField.toggle() }
                } label: {
                    Label(showingField ? "controls" : "field",
                          systemImage: showingField ? "slider.horizontal.3" : "waveform.path.ecg")
                        .font(Theme.monoSmall).foregroundColor(Theme.mid)
                }.buttonStyle(.plain)
                    .tip("switch between performance direction and the modulation field")
            }

            if showingField {
                HStack(alignment: .top, spacing: 12) {
                    FieldView(field: model.field, isPlaying: { model.playing },
                              barDuration: { model.barDuration })
                    VStack(alignment: .leading, spacing: 6) {
                        Text("The field is observed here, not given a permanent third of the instrument.")
                            .font(Theme.monoSmall).foregroundColor(Theme.mid)
                        Text(String(format: "interest %.2f", model.snapshot.interest.overall))
                            .font(Theme.mono).foregroundColor(Theme.accent)
                        Text("weakest \(model.snapshot.interest.worst)")
                            .font(Theme.monoSmall).foregroundColor(Theme.dim)
                        Button("purposeful surprise") { model.requestSurprise() }
                            .buttonStyle(.bordered).controlSize(.small).tint(Theme.accent)
                    }
                }
                .transition(.opacity)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    globalChoices.frame(width: 193)
                    directionControls.frame(maxWidth: .infinity)
                }
                .transition(.opacity)
            }
            Spacer(minLength: 0)
            if !model.statusMessage.isEmpty {
                Text(model.statusMessage).font(Theme.monoSmall).foregroundColor(Theme.accent)
                    .lineLimit(1)
            }
        }
        .padding(10)
    }

    private var globalChoices: some View {
        VStack(spacing: 6) {
            SegmentedValueControl(label: "motif", value: $model.motifRecurrence,
                                  choices: motifChoices,
                                  tip: TipContent(title: "motif memory",
                                      summary: "Chooses how often melody material returns transformed.",
                                      range: "fresh · balanced · thematic",
                                      context: "This is phrase memory, not repeated-note likelihood."))
            SegmentedValueControl(label: "section pace", value: $model.sectionLength,
                                  choices: sectionChoices,
                                  tip: TipContent(title: "section pace",
                                      summary: "Sets the nominal macro-form span before profile-specific shaping.",
                                      range: "12 · 24 · 36 · 48 bars",
                                      context: "Boundaries remain quantized to four-bar phrases."))
            SegmentedValueControl(label: "voice link", value: $model.link,
                                  choices: linkChoices,
                                  tip: TipContent(title: "voice link",
                                      summary: "Controls whether slow parameter movement is shared or independent.",
                                      range: "independent · mixed · linked"))
            SegmentedValueControl(label: "harmony wander", value: $model.wander,
                                  choices: wanderChoices,
                                  tip: TipContent(title: "harmony wander",
                                      summary: "Allows lawful functional substitutions while preserving cadences.",
                                      range: "classic · subtle · roaming"))
        }
    }

    private var directionControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            compactPicker("sync", selection: $model.clockMode) {
                ForEach(ClockMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            compactPicker("groove", selection: $model.grooveStyle) {
                Text("auto · \(model.snapshot.grooveLabel)").tag(nil as DrumGenerator.GrooveStyle?)
                ForEach(DrumGenerator.GrooveStyle.allCases, id: \.self) {
                    Text($0.rawValue).tag(Optional($0))
                }
            }
            compactPicker("dialect", selection: $model.harmonyDialect) {
                Text("auto · \(model.snapshot.dialectLabel)").tag(nil as HarmonicDialect?)
                ForEach(HarmonicDialect.allCases, id: \.self) {
                    Text($0.rawValue).tag(Optional($0))
                }
            }
            HStack(spacing: 4) {
                cueButton("build → drop") { model.queueCue(.buildDrop) }
                cueButton("breakdown") { model.queueCue(.breakdown) }
            }
            HStack(spacing: 4) {
                cueButton("next section") { model.queueCue(.nextSection) }
                cueButton("clear cues") { model.clearQueuedCues() }
            }
            Text(cueStatus).font(Theme.monoSmall).foregroundColor(Theme.accent).lineLimit(1)
        }
    }

    private var cueStatus: String {
        if !model.snapshot.queuedCueLabel.isEmpty, let bar = model.snapshot.queuedCueBar {
            return "queued \(model.snapshot.queuedCueLabel) · \(max(0, bar - model.snapshot.bar)) bars"
        }
        if !model.snapshot.activeCueLabel.isEmpty { return "live · \(model.snapshot.activeCueLabel)" }
        return "auto · \(model.snapshot.formProfile.rawValue)"
    }

    private func compactPicker<T: Hashable, Content: View>(_ label: String,
        selection: Binding<T>, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6) {
            Text(label).font(Theme.monoSmall).foregroundColor(Theme.dim).frame(width: 48, alignment: .leading)
            Picker("", selection: selection, content: content)
                .labelsHidden().controlSize(.small).frame(maxWidth: .infinity)
        }
    }

    // MARK: - Small pieces

    private let driftChoices = [ControlChoice(label: "static", value: 0),
                                ControlChoice(label: "gentle", value: 0.5),
                                ControlChoice(label: "free", value: 1)]
    private let motifChoices = [ControlChoice(label: "fresh", value: 0.20),
                                ControlChoice(label: "balanced", value: 0.68),
                                ControlChoice(label: "thematic", value: 0.90)]
    private let sectionChoices = [ControlChoice(label: "12", value: 8.0 / 60.0),
                                  ControlChoice(label: "24", value: 20.0 / 60.0),
                                  ControlChoice(label: "36", value: 32.0 / 60.0),
                                  ControlChoice(label: "48", value: 44.0 / 60.0)]
    private let linkChoices = [ControlChoice(label: "ind", value: 0),
                               ControlChoice(label: "mixed", value: 0.35),
                               ControlChoice(label: "linked", value: 0.85)]
    private let wanderChoices = [ControlChoice(label: "classic", value: 0),
                                 ControlChoice(label: "subtle", value: 0.42),
                                 ControlChoice(label: "roaming", value: 0.80)]

    private func nearest(_ value: Double, in choices: [ControlChoice]) -> Double {
        choices.min(by: { abs($0.value - value) < abs($1.value - value) })?.value ?? value
    }

    private func voiceSummary(_ voice: Voice) -> String {
        switch voice {
        case .drone: return "sustained harmonic foundation"
        case .drums: return "standard Ableton kit grammar"
        case .bass: return "root-bearing shared-anchor line"
        case .chords: return "voice-led pad atmosphere"
        case .pulse: return "chord-locked rhythmic motion"
        case .melody: return "withholding motif and phase line"
        }
    }

    private func headerLabel<V: View>(_ label: String, @ViewBuilder content: () -> V) -> some View {
        HStack(spacing: 4) {
            Text(label).font(Theme.monoSmall).foregroundColor(Theme.dim)
            content()
        }
    }

    private func transportButton(_ icon: String, active: Bool,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11, weight: .bold))
                .foregroundColor(active ? .white : Theme.text)
                .frame(width: 31, height: 25)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(active ? Theme.accent : Theme.well))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .stroke(Theme.hairline.opacity(active ? 0 : 0.7), lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private func cueButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(Theme.monoSmall).foregroundColor(Theme.text)
                .frame(maxWidth: .infinity).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.well))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(Theme.hairline.opacity(0.65), lineWidth: 1))
        }.buttonStyle(.plain)
    }
}

/// A number you drag vertically — no slider real estate.
struct DragNumber: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String
    @State private var start: Double? = nil

    var body: some View {
        Text(String(format: format, value))
            .font(Theme.mono).foregroundColor(Theme.text).frame(width: 40)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.well))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .stroke(Theme.hairline.opacity(0.7), lineWidth: 1))
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { gesture in
                    if start == nil { start = value }
                    let span = range.upperBound - range.lowerBound
                    value = min(range.upperBound, max(range.lowerBound,
                        (start ?? value) - Double(gesture.translation.height) / 140 * span * 0.5))
                }
                .onEnded { _ in start = nil })
    }
}

struct SeedEditor: View {
    @ObservedObject var model: AppModel
    @State private var text = ""

    var body: some View {
        TextField("seed", text: $text)
            .textFieldStyle(.plain).font(Theme.mono).foregroundColor(Theme.text)
            .frame(width: 126).padding(.vertical, 4).padding(.horizontal, 5)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.well))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .stroke(Theme.hairline.opacity(0.7), lineWidth: 1))
            .onAppear { sync() }.onChange(of: model.seed) { sync() }.onSubmit { commit() }
            .tip("full 64-bit seed — paste hexadecimal or decimal and press return")
    }

    private func sync() { text = String(format: "%016llx", model.seed) }
    private func commit() {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = raw.hasPrefix("0x") ? String(raw.dropFirst(2)) : raw
        if let value = UInt64(hex, radix: 16) ?? UInt64(raw) { model.applySeed(max(1, value)) }
        sync()
    }
}

struct OnboardingView: View {
    @ObservedObject var model: AppModel
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("loom is ready to weave")
                .font(.system(size: 24, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.text)
            Text("Loom publishes six musical MIDI ports plus clock. Use the reference monitor for an immediate sketch, or route each port to a sound you love in your DAW.")
                .font(.system(size: 13)).foregroundColor(Theme.mid)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                route("loom drone", "dark pad · CC24 swell")
                route("loom drums", "kick 36 · snare 38 · hats 42/46")
                route("loom bass", "mono bass · portamento CC5/65")
                route("loom chords", "warm poly pad")
                route("loom pulse", "chord-locked rhythmic synth")
                route("loom melody", "lead · pressure + portamento")
                route("loom clock", "24 PPQN start / stop")
                route("loom sync in", "Ableton clock / transport input")
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.well.opacity(0.55)))
            Text("Every musical port: CC1 tension · CC11 expression · CC20–23 modulation · CC25 build · CC26 drop · CC74 brightness.")
                .font(Theme.monoSmall).foregroundColor(Theme.mid)
            HStack {
                Button("Use reference monitor") { model.monitorEnabled = true; done() }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                Button("Route to my DAW") { done() }.buttonStyle(.bordered)
                Spacer()
            }
        }
        .padding(24).frame(width: 560).background(Theme.surface)
    }

    private func route(_ port: String, _ role: String) -> some View {
        HStack {
            Text(port).font(Theme.mono).foregroundColor(Theme.text)
                .frame(width: 120, alignment: .leading)
            Text(role).font(Theme.monoSmall).foregroundColor(Theme.mid)
        }
    }
}
