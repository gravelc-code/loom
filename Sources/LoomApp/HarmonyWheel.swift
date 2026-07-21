import SwiftUI
import LoomCore

/// A circle of fifths that twins the orbit's radial language. C sits at 12
/// o'clock; each step clockwise is a perfect fifth, so related keys are
/// neighbours and a key journey reads as a short walk around the ring. The
/// sounding key's diatonic notes are shaded into a contiguous arc, the current
/// chord's tones are lit dots, the tonic carries an accent marker, and — when
/// the piece has modulated away from home — the home tonic keeps a ghost ring
/// so you can see how far loom has wandered. Purely a readout of the snapshot;
/// it never feeds back into generation.
struct HarmonyWheel: View {
    @ObservedObject var model: AppModel

    /// Smooth display clock, shared timing model with the orbit, so the live
    /// voice ticks land in step with the hand sweeping the mandala.
    @State private var clock = MotionClock()

    /// Pitch-class spelling chosen to read well on the wheel (flats on the
    /// flat side, sharps on the sharp side).
    private static let pcName = ["C", "D♭", "D", "E♭", "E", "F",
                                 "F♯", "G", "A♭", "A", "B♭", "B"]

    /// Clockwise wheel index (0 = C at top) for a pitch class, and back.
    /// 7 is its own inverse mod 12, so both directions multiply by 7.
    private static func index(ofPC pc: Int) -> Int { (norm(pc) * 7) % 12 }
    private static func pc(atIndex k: Int) -> Int { (k * 7) % 12 }
    private static func norm(_ n: Int) -> Int { ((n % 12) + 12) % 12 }

    var body: some View {
        VStack(spacing: 3) {
            TimelineView(.animation) { timeline in
                Canvas { ctx, size in draw(ctx, size: size, date: timeline.date) }
            }
            .frame(height: 104)

            Text("now \(compact(model.snapshot.chordLabel)) → \(compact(model.snapshot.nextChordLabel))")
                .font(Theme.monoSmall).foregroundColor(Theme.accent)
                .lineLimit(1)
            Text(keyLine)
                .font(Theme.monoSmall).foregroundColor(Theme.mid)
                .lineLimit(1)
        }
        .tip("circle of fifths. shaded arc: the sounding key's scale. lit dots: the current chord's notes. accent marker: the tonic. inner colored ticks: where bass, chords, pulse and melody are sounding right now. a ghost ring marks home key when the piece has modulated away.")
    }

    // MARK: - drawing

    private func draw(_ ctx: GraphicsContext, size: CGSize, date: Date) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let R = min(size.width, size.height) / 2 - 13   // room for the labels
        let snap = model.snapshot
        let t = date.timeIntervalSinceReferenceDate

        let keyPC = Self.norm(snap.keyRoot)
        let homePC = Self.norm(snap.homeKeyRoot)
        let away = keyPC != homePC || snap.keyScale != snap.homeScale
        let chordPCs = Set(snap.chordPCs.map(Self.norm))

        // Light plate, echoing the orbit's ground.
        ctx.fill(Path(ellipseIn: circleRect(c, R + 9)), with: .color(Theme.weaveGround))

        // Scale-tone shading: a soft wedge behind every diatonic note. On the
        // circle of fifths a key's seven notes are contiguous, so this reads as
        // one lit arc.
        for p in 0..<12 where p < snap.scaleMask.count && snap.scaleMask[p] {
            let a = angle(Self.index(ofPC: p))
            var wedge = Path()
            wedge.move(to: c)
            wedge.addArc(center: c, radius: R + 6,
                         startAngle: .radians(a - .pi / 12), endAngle: .radians(a + .pi / 12),
                         clockwise: false)
            wedge.closeSubpath()
            ctx.fill(wedge, with: .color(Theme.accent.opacity(0.09)))
        }

        // The ring.
        ctx.stroke(Path(ellipseIn: circleRect(c, R)),
                   with: .color(Theme.hairline.opacity(0.5)), lineWidth: 1)

        // Home ghost ring, when the piece has journeyed away.
        if away {
            let hp = point(c, R, angle(Self.index(ofPC: homePC)))
            ctx.stroke(Path(ellipseIn: CGRect(x: hp.x - 6, y: hp.y - 6, width: 12, height: 12)),
                       with: .color(Theme.dim.opacity(0.7)), lineWidth: 1)
        }

        // Nodes: label every pitch class; light the chord tones and the tonic.
        let pulse = 0.75 + 0.25 * sin(t * 2.2)
        for k in 0..<12 {
            let p = Self.pc(atIndex: k)
            let a = angle(k)
            let pos = point(c, R, a)
            let inChord = chordPCs.contains(p)
            let isTonic = p == keyPC

            if inChord {
                let r: CGFloat = isTonic ? 5 : 3.5
                // Halo for the tonic; a lit dot for every chord tone.
                if isTonic {
                    ctx.fill(Path(ellipseIn: CGRect(x: pos.x - r - 3, y: pos.y - r - 3,
                                                    width: (r + 3) * 2, height: (r + 3) * 2)),
                             with: .color(Theme.accent.opacity(0.22 * pulse)))
                }
                ctx.fill(Path(ellipseIn: CGRect(x: pos.x - r, y: pos.y - r, width: r * 2, height: r * 2)),
                         with: .color((isTonic ? Theme.accentBright : Theme.accent).opacity(0.85)))
            } else if isTonic {
                // Tonic that isn't currently sounding still gets a marker ring.
                ctx.stroke(Path(ellipseIn: CGRect(x: pos.x - 5, y: pos.y - 5, width: 10, height: 10)),
                           with: .color(Theme.accent.opacity(0.8)), lineWidth: 1.5)
            } else {
                ctx.fill(Path(ellipseIn: CGRect(x: pos.x - 1.5, y: pos.y - 1.5, width: 3, height: 3)),
                         with: .color(Theme.hairline.opacity(0.7)))
            }

            // Label just outside the ring.
            let lp = point(c, R + 8.5, a)
            let isScale = p < snap.scaleMask.count && snap.scaleMask[p]
            ctx.draw(Text(Self.pcName[p])
                        .font(.system(size: 8, weight: isTonic ? .bold : .regular, design: .monospaced))
                        .foregroundColor(isTonic ? Theme.accent : (isScale ? Theme.text : Theme.dim)),
                     at: lp)
        }

        // Live voice positions: a colored tick for wherever bass, chords,
        // pulse and melody are sounding this instant, set just inside the ring
        // so the wheel shows the voices moving around the frame — not only the
        // drone-shared root and fifth. Timed by the same smooth clock as the
        // orbit; a pure readout of the roll, so determinism is untouched.
        let displayed = clock.advance(
            playing: model.playing,
            polledBar: model.playhead.bar, polledPhase: model.playhead.phase,
            anchor: model.playheadAnchor, barDuration: model.barDuration,
            now: date)
        let steps = displayed * 16.0
        let phBar = model.playhead.bar
        let voiceSlot: [Voice: CGFloat] = [.bass: 4, .chords: 8, .pulse: 12, .melody: 16]
        var ticks: [(pos: CGPoint, col: Color)] = []
        for entry in model.roll where entry.bar >= phBar - 1 && entry.bar <= phBar + 1 {
            for n in entry.notes {
                guard let slot = voiceSlot[n.voice] else { continue }   // pitched voices only
                let delta = steps - (Double(entry.bar) * 16 + n.startStep)
                guard delta >= 0, delta <= max(0.5, n.durationSteps) else { continue }
                ticks.append((point(c, R - slot, angle(Self.index(ofPC: Self.norm(n.note)))),
                              Theme.voiceColor(n.voice)))
            }
        }
        // Three passes so overlapping voices stay legible: breathing glows
        // underneath, a ground-colored moat around each, then the bold ticks.
        for tk in ticks {
            ctx.fill(Path(ellipseIn: CGRect(x: tk.pos.x - 4, y: tk.pos.y - 4, width: 8, height: 8)),
                     with: .color(tk.col.opacity(0.30 * pulse)))
        }
        for tk in ticks {
            ctx.fill(Path(ellipseIn: CGRect(x: tk.pos.x - 3, y: tk.pos.y - 3, width: 6, height: 6)),
                     with: .color(Theme.weaveGround))
        }
        for tk in ticks {
            ctx.fill(Path(ellipseIn: CGRect(x: tk.pos.x - 2.3, y: tk.pos.y - 2.3, width: 4.6, height: 4.6)),
                     with: .color(tk.col))
        }

        // Center: the sounding key.
        ctx.draw(Text(keyName(keyPC, snap.keyScale))
                    .font(Theme.monoBig).foregroundColor(Theme.text),
                 at: c)
    }

    // MARK: - text helpers

    private var keyLine: String {
        let snap = model.snapshot
        let key = "\(Self.pcName[Self.norm(snap.keyRoot)]) \(shortScale(snap.keyScale))"
        if Self.norm(snap.keyRoot) == Self.norm(snap.homeKeyRoot) && snap.keyScale == snap.homeScale {
            return "\(key) · home"
        }
        let home = "\(Self.pcName[Self.norm(snap.homeKeyRoot)]) \(shortScale(snap.homeScale))"
        return "\(key) ← home \(home) · mvt \(snap.movement + 1)"
    }

    /// Root + a compact quality suffix for the center glyph.
    private func keyName(_ pc: Int, _ scale: Scale) -> String {
        Self.pcName[Self.norm(pc)] + (isMinorFamily(scale) ? "m" : "")
    }

    private func isMinorFamily(_ scale: Scale) -> Bool {
        switch scale {
        case .minor, .dorian, .phrygian: return true
        case .major, .mixolydian, .lydian: return false
        }
    }

    private func shortScale(_ scale: Scale) -> String {
        switch scale {
        case .minor: return "min"
        case .major: return "maj"
        case .dorian: return "dor"
        case .phrygian: return "phr"
        case .mixolydian: return "mix"
        case .lydian: return "lyd"
        }
    }

    /// "Am (i)" → "Am"; leaves plain labels untouched.
    private func compact(_ label: String) -> String {
        if let i = label.firstIndex(of: "(") {
            return String(label[..<i]).trimmingCharacters(in: .whitespaces)
        }
        return label
    }

    // MARK: - geometry (12 o'clock origin, clockwise — matches OrbitView)

    private func angle(_ k: Int) -> Double { -Double.pi / 2 + 2 * .pi * Double(k) / 12 }
    private func point(_ c: CGPoint, _ r: CGFloat, _ a: Double) -> CGPoint {
        CGPoint(x: c.x + r * CGFloat(cos(a)), y: c.y + r * CGFloat(sin(a)))
    }
    private func circleRect(_ c: CGPoint, _ r: CGFloat) -> CGRect {
        CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
    }
}
