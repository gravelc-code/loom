import SwiftUI
import LoomCore

let uiVoiceOrder: [Voice] = [.drone, .drums, .bass, .chords, .pulse, .melody]

struct VoiceStrip: View {
    @ObservedObject var model: AppModel
    let voice: Voice
    @Binding var selected: Voice

    private var isSelected: Bool { selected == voice }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.voiceColor(voice))
                    .frame(width: 7, height: 18)
                Text(voice.rawValue).font(Theme.bayTitle).foregroundColor(Theme.text)
                Spacer()
                activity
            }

            if voice == .drone {
                HStack {
                    Text("foundation").font(Theme.monoSmall).foregroundColor(Theme.dim)
                    Spacer()
                    Text(model.snapshot.active[voice] == true ? "held" : "ready")
                        .font(Theme.monoSmall).foregroundColor(Theme.voiceColor(voice))
                }
                .frame(height: 16)
            } else {
                Slider(value: model.paramBinding(voice, "amount"), in: 0...1)
                    .controlSize(.mini).tint(Theme.voiceColor(voice))
                    .tip(ControlCatalog.controls(for: voice).first(where: { $0.name == "amount" })!
                        .tip(base: model.paramBinding(voice, "amount").wrappedValue,
                             live: model.effectiveValue(voice, "amount")))
            }

            HStack(spacing: 9) {
                stripButton((model.locked[voice] ?? false) ? "lock.fill" : "lock.open",
                            active: model.locked[voice] ?? false) {
                    model.lockBinding(voice).wrappedValue.toggle()
                }
                .tip("lock the voice's seed and controls while the rest evolves")
                stripTextButton("M", active: model.muted[voice] ?? false) { model.toggleMute(voice) }
                    .tip("mute this MIDI voice without changing its generated part")
                stripTextButton("S", active: model.soloed == voice) { model.toggleSolo(voice) }
                    .tip("solo this voice")
                stripButton("speaker.wave.1", active: false) { model.audition(voice) }
                    .tip("audition this MIDI port")
                Spacer()
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(isSelected ? Theme.voiceColor(voice) : Theme.dim)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 84)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(isSelected ? Theme.weaveGround : Theme.raised))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(isSelected ? Theme.voiceColor(voice) : Theme.hairline.opacity(0.55),
                    lineWidth: isSelected ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { selected = voice }
        }
    }

    private var activity: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.well)
                Capsule().fill(Theme.voiceColor(voice))
                    .frame(width: max(2, geo.size.width
                        * CGFloat(model.snapshot.activity[voice] ?? 0)))
            }
        }
        .frame(width: 34, height: 5)
    }

    private func stripButton(_ icon: String, active: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 9, weight: .semibold))
                .foregroundColor(active ? .white : Theme.dim)
                .frame(width: 18, height: 18)
                .background(Circle().fill(active ? Theme.voiceColor(voice) : .clear))
        }.buttonStyle(.plain)
    }

    private func stripTextButton(_ text: String, active: Bool,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(Theme.monoSmall)
                .foregroundColor(active ? .white : Theme.dim)
                .frame(width: 18, height: 18)
                .background(Circle().fill(active ? Theme.voiceColor(voice) : .clear))
        }.buttonStyle(.plain)
    }
}

/// Thirty-two absolute bars of actual conductor state. Unlike the former
/// section horizon, this advances every bar and exposes voice entries and
/// structural events at the scale at which they are heard.
struct RollingFormStrip: View {
    let snapshot: EngineSnapshot
    @ObservedObject var playhead: PlayheadModel

    var body: some View {
        Canvas { ctx, size in
            let preview = snapshot.arrangementPreview
            guard !preview.isEmpty else { return }
            let barW = size.width / CGFloat(preview.count)
            let graphBottom = size.height - 30

            for (index, bar) in preview.enumerated() {
                let x = CGFloat(index) * barW
                let shade: Double
                switch bar.section {
                case .intro: shade = 0.035
                case .develop: shade = 0.07
                case .peak: shade = 0.14
                case .breakdown: shade = 0.05
                }
                ctx.fill(Path(CGRect(x: x, y: 0, width: barW, height: graphBottom)),
                         with: .color(Theme.accent.opacity(shade)))
                if index == 0 || preview[index - 1].section != bar.section {
                    ctx.stroke(Path { p in
                        p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
                    }, with: .color(Theme.hairline.opacity(0.7)), lineWidth: 1)
                    ctx.draw(Text(bar.section.rawValue).font(Theme.monoSmall)
                        .foregroundColor(Theme.mid),
                        at: CGPoint(x: min(size.width - 28, x + 24), y: 7))
                }

                for (voiceIndex, voice) in uiVoiceOrder.enumerated()
                    where bar.activeVoices.contains(voice) {
                    let marker = CGRect(x: x + 1,
                                      y: graphBottom + 3 + CGFloat(voiceIndex) * 4,
                                      width: max(1.5, barW - 2), height: 2)
                    ctx.fill(Path(roundedRect: marker, cornerRadius: 1),
                             with: .color(Theme.voiceColor(voice).opacity(0.88)))
                }

                if let event = bar.event {
                    let glyph: String
                    switch event {
                    case .build: glyph = "↗"
                    case .vacuum: glyph = "○"
                    case .drop: glyph = "◆"
                    case .exhale: glyph = "↓"
                    }
                    ctx.draw(Text(glyph).font(.system(size: 9, weight: .bold))
                        .foregroundColor(Theme.accent),
                        at: CGPoint(x: x + barW / 2, y: 18))
                }
                if bar.cue != nil {
                    ctx.draw(Text("▾").font(.system(size: 8, weight: .bold))
                        .foregroundColor(Theme.accentBright),
                        at: CGPoint(x: x + barW / 2, y: 29))
                }
            }

            var tension = Path()
            for (index, bar) in preview.enumerated() {
                let point = CGPoint(x: (CGFloat(index) + 0.5) * barW,
                                    y: graphBottom - 3 - CGFloat(bar.tension) * (graphBottom - 15))
                index == 0 ? tension.move(to: point) : tension.addLine(to: point)
            }
            ctx.stroke(tension, with: .color(Theme.text.opacity(0.78)), lineWidth: 1.5)

            let liveX = min(size.width, max(0, CGFloat(playhead.phase) * barW))
            ctx.stroke(Path { p in
                p.move(to: CGPoint(x: liveX, y: 0)); p.addLine(to: CGPoint(x: liveX, y: size.height))
            }, with: .color(Theme.accent), lineWidth: 2)
        }
        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.weaveGround))
        .overlay(RoundedRectangle(cornerRadius: 5)
            .stroke(Theme.hairline.opacity(0.55), lineWidth: 1))
        .tip(TipContent(title: "32-bar form",
                        summary: "The real seeded conductor plan, advancing one bar at a time.",
                        range: "line = tension · colored rows = active voices",
                        values: "↗ build · ○ vacuum · ◆ drop · ↓ breakdown · ▾ queued cue",
                        context: "Profile: \(snapshot.formProfile.rawValue). Rewind reproduces it exactly."))
    }
}

struct RollLegend: View {
    @Binding var selected: Voice

    var body: some View {
        HStack(spacing: 5) {
            ForEach(uiVoiceOrder, id: \.self) { voice in
                Button { selected = voice } label: {
                    HStack(spacing: 4) {
                        legendMark(voice)
                        Text(voice.rawValue).font(Theme.monoSmall)
                    }
                    .foregroundColor(selected == voice ? Theme.text : Theme.mid)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4)
                        .fill(selected == voice ? Theme.voiceColor(voice).opacity(0.15) : .clear))
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .stroke(selected == voice ? Theme.voiceColor(voice) : .clear, lineWidth: 1))
                }.buttonStyle(.plain)
            }
            Spacer()
            Text("color + shape identify every port")
                .font(Theme.monoSmall).foregroundColor(Theme.dim)
        }
    }

    @ViewBuilder private func legendMark(_ voice: Voice) -> some View {
        switch voice {
        case .drums:
            Rectangle().fill(Theme.voiceColor(voice)).frame(width: 7, height: 7)
                .rotationEffect(.degrees(45))
        case .drone:
            RoundedRectangle(cornerRadius: 1).fill(Theme.voiceColor(voice))
                .frame(width: 12, height: 6)
                .overlay(RoundedRectangle(cornerRadius: 1).stroke(Theme.text, lineWidth: 1))
        case .chords:
            ZStack {
                RoundedRectangle(cornerRadius: 1).fill(Theme.voiceColor(voice).opacity(0.5))
                    .frame(width: 12, height: 6).offset(y: -2)
                RoundedRectangle(cornerRadius: 1).fill(Theme.voiceColor(voice).opacity(0.8))
                    .frame(width: 12, height: 6).offset(y: 2)
            }.frame(width: 12, height: 10)
        case .pulse:
            Capsule().fill(Theme.voiceColor(voice)).frame(width: 12, height: 3)
        case .bass:
            Capsule().fill(Theme.voiceColor(voice)).frame(width: 12, height: 6)
        case .melody:
            Capsule().fill(Theme.voiceColor(voice)).frame(width: 12, height: 4)
        }
    }
}

struct PerformancePianoRoll: View {
    @ObservedObject var model: AppModel
    @ObservedObject var playhead: PlayheadModel
    let selected: Voice

    private let lowNote = 22, highNote = 102
    private let gutter: CGFloat = 25

    // Navigation state. `follow` re-locks the window to the playhead; otherwise
    // `originBar` (the bar at the left edge) and `visibleBars` (zoom) are held.
    @State private var visibleBars: Double = 12
    @State private var originBar: Double = 0
    @State private var follow = true
    @State private var dragAnchor: Double? = nil
    @State private var zoomAnchor: Double = 12
    // Smooth 60 fps display clock so the playhead and follow-scroll glide
    // instead of stepping at the 15 Hz poll rate.
    @State private var clock = MotionClock()

    /// In follow mode the playhead sits near the left, so most of the roll shows
    /// the provisional lookahead ahead of it.
    private let followFrac = 0.2

    var body: some View {
        GeometryReader { geo in
            let drawable = max(1, geo.size.width - gutter)
            let pxPerBar = drawable / visibleBars
            TimelineView(.animation) { timeline in
                Canvas { ctx, size in
                    let displayed = clock.advance(
                        playing: model.playing,
                        polledBar: playhead.bar, polledPhase: playhead.phase,
                        anchor: model.playheadAnchor, barDuration: model.barDuration,
                        now: timeline.date)
                    let left = follow ? displayed - visibleBars * followFrac : originBar
                    drawRoll(ctx, size: size, originBar: left, playStep: displayed * 16)
                }
            }
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(Color(red: 0.972, green: 0.966, blue: 0.955)))   // pale, so notes pop
            .overlay(RoundedRectangle(cornerRadius: 5)
                .stroke(Theme.hairline.opacity(0.55), lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                if !follow {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { follow = true }
                    } label: {
                        Label("live", systemImage: "dot.radiowaves.left.and.right")
                            .font(Theme.monoSmall).foregroundColor(Theme.accent)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 5)
                                .fill(Theme.raised).overlay(RoundedRectangle(cornerRadius: 5)
                                    .stroke(Theme.accent.opacity(0.5), lineWidth: 1)))
                    }.buttonStyle(.plain).padding(6)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { v in
                        if dragAnchor == nil {
                            let coarse = Double(playhead.bar) + playhead.phase
                            dragAnchor = follow ? coarse - visibleBars * followFrac : originBar
                            follow = false
                        }
                        originBar = (dragAnchor ?? originBar) - Double(v.translation.width) / pxPerBar
                    }
                    .onEnded { _ in dragAnchor = nil }
            )
            .gesture(
                MagnificationGesture()
                    .onChanged { scale in
                        visibleBars = min(64, max(2, zoomAnchor / Double(scale)))
                    }
                    .onEnded { _ in zoomAnchor = visibleBars }
            )
            .tip(TipContent(title: "MIDI piano roll",
                            summary: "Pitch vertically, time horizontally. Drag to scroll, pinch to zoom.",
                            range: "width = duration · ink = velocity · shape = port · faded = upcoming",
                            values: "Selected voice is emphasized; scroll back to review the piece.",
                            context: "Tap live to re-lock to the playhead."))
        }
    }

    private func drawRoll(_ ctx: GraphicsContext, size: CGSize,
                          originBar: Double, playStep: Double) {
        let drawable = max(1, size.width - gutter)
        let span = Double(highNote - lowNote)
        func x(_ barPos: Double) -> CGFloat {
            gutter + CGFloat((barPos - originBar) / visibleBars) * drawable
        }
        func y(_ note: Int) -> CGFloat {
            size.height * CGFloat(1 - (Double(note - lowNote) / span))
        }

        for c in stride(from: 24, through: 96, by: 12) {
            let yy = y(c)
            ctx.stroke(Path { p in
                p.move(to: CGPoint(x: gutter, y: yy)); p.addLine(to: CGPoint(x: size.width, y: yy))
            }, with: .color(Theme.hairline.opacity(0.28)), lineWidth: 0.5)
            ctx.draw(Text("C\(c / 12 - 1)").font(.system(size: 8, design: .monospaced))
                .foregroundColor(Theme.dim), at: CGPoint(x: 11, y: yy))
        }
        // Bar lines across the visible span, heavier every four bars.
        let firstLine = Int(originBar.rounded(.down))
        let lastLine = Int((originBar + visibleBars).rounded(.up))
        for bar in firstLine...lastLine {
            let xx = x(Double(bar))
            guard xx >= gutter - 1 else { continue }
            ctx.stroke(Path { p in
                p.move(to: CGPoint(x: xx, y: 0)); p.addLine(to: CGPoint(x: xx, y: size.height))
            }, with: .color(Theme.hairline.opacity(bar % 4 == 0 ? 0.7 : 0.32)),
               lineWidth: bar % 4 == 0 ? 1 : 0.5)
        }

        let window = model.roll
        guard !window.isEmpty else {
            ctx.draw(Text("▶  press play to weave").font(Theme.mono).foregroundColor(Theme.mid),
                     at: CGPoint(x: size.width / 2, y: size.height / 2))
            return
        }
        let visibleRange = (originBar - 0.1)...(originBar + visibleBars + 0.1)
        for entry in window {
            for note in entry.notes {
                let start = Double(entry.bar) + note.startStep / 16
                let end = start + note.durationSteps / 16
                guard end > visibleRange.lowerBound, start < visibleRange.upperBound else { continue }
                let xx = x(start), width = max(2.5, x(end) - xx)
                let yy = y(note.note)
                let emphasis = note.voice == selected ? 1.0 : 0.34
                let velocity = 0.50 + Double(note.velocity) / 127 * 0.50
                // Notes whose onset is ahead of the playhead are upcoming — the
                // engine has generated but not yet played them.
                let upcoming = (Double(entry.bar) * 16 + note.startStep) > playStep + 0.01
                draw(note: note, in: ctx,
                     rect: CGRect(x: xx, y: yy - 2, width: width, height: 4),
                     opacity: emphasis * velocity, upcoming: upcoming)
            }
        }

        // Provisional lookahead: bars the engine has generated for display but
        // not committed to MIDI. They reshape live as controls are edited.
        for entry in model.lookahead {
            for note in entry.notes {
                let start = Double(entry.bar) + note.startStep / 16
                let end = start + note.durationSteps / 16
                guard end > visibleRange.lowerBound, start < visibleRange.upperBound else { continue }
                let xx = x(start), width = max(2.5, x(end) - xx)
                let yy = y(note.note)
                let emphasis = note.voice == selected ? 1.0 : 0.34
                let velocity = 0.50 + Double(note.velocity) / 127 * 0.50
                draw(note: note, in: ctx,
                     rect: CGRect(x: xx, y: yy - 2, width: width, height: 4),
                     opacity: emphasis * velocity, upcoming: true)
            }
        }

        let px = x(playStep / 16)
        if px >= gutter {
            ctx.stroke(Path { p in
                p.move(to: CGPoint(x: px, y: 0)); p.addLine(to: CGPoint(x: px, y: size.height))
            }, with: .color(Theme.accent.opacity(0.25)), lineWidth: 5)
            ctx.stroke(Path { p in
                p.move(to: CGPoint(x: px, y: 0)); p.addLine(to: CGPoint(x: px, y: size.height))
            }, with: .color(Theme.accentBright), lineWidth: 1.5)
        }
    }

    private func draw(note: NoteSummary, in ctx: GraphicsContext,
                      rect: CGRect, opacity: Double, upcoming: Bool) {
        let vc = Theme.voiceColor(note.voice)
        // Played notes are solid. Upcoming (not-yet-played) notes are drawn
        // hollow — a faint fill plus a crisp full-colour outline — so when they
        // stack up they stay legible instead of blending into a soft wash.
        func render(_ p: Path, fill: Double = 1) {
            if upcoming {
                // Bright, crisp outline (never too faint, even for non-selected
                // voices) + a light fill, so stacked upcoming notes stay legible.
                ctx.fill(p, with: .color(vc.opacity(opacity * 0.20)))
                ctx.stroke(p, with: .color(vc.opacity(min(1, max(0.62, opacity * 1.6)))),
                           lineWidth: 1.4)
            } else {
                ctx.fill(p, with: .color(vc.opacity(opacity * fill)))
            }
        }
        switch note.voice {
        case .drums:
            let side: CGFloat = 6
            let c = CGPoint(x: rect.minX + side / 2, y: rect.midY)
            var p = Path()
            p.move(to: CGPoint(x: c.x, y: c.y - side / 2))
            p.addLine(to: CGPoint(x: c.x + side / 2, y: c.y))
            p.addLine(to: CGPoint(x: c.x, y: c.y + side / 2))
            p.addLine(to: CGPoint(x: c.x - side / 2, y: c.y))
            p.closeSubpath()
            render(p)
        case .drone:
            let p = Path(roundedRect: CGRect(x: rect.minX, y: rect.midY - 3.5,
                                             width: rect.width, height: 7), cornerRadius: 1.5)
            render(p, fill: 0.72)
            if !upcoming { ctx.stroke(p, with: .color(vc.opacity(opacity)), lineWidth: 1.2) }
        case .chords:
            render(Path(roundedRect: CGRect(x: rect.minX, y: rect.midY - 2.5,
                                            width: rect.width, height: 5), cornerRadius: 1.5), fill: 0.62)
        case .pulse:
            render(Path(roundedRect: CGRect(x: rect.minX, y: rect.midY - 1.3,
                                            width: rect.width, height: 2.6), cornerRadius: 2))
        case .bass:
            render(Path(roundedRect: CGRect(x: rect.minX, y: rect.midY - 3,
                                            width: rect.width, height: 6), cornerRadius: 3))
        case .melody:
            render(Path(roundedRect: CGRect(x: rect.minX, y: rect.midY - 2.5,
                                            width: rect.width, height: 5), cornerRadius: 2.5))
        }
    }
}
