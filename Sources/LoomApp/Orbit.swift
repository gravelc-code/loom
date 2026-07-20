import SwiftUI
import LoomCore

/// The loom as an orbital mandala. One revolution = one bar; a hand sweeps
/// clockwise from 12 o'clock. The drone breathes at the core; each drum
/// track is a thin ring; ornament tracks gain their own polymetric loop only
/// when the performance's `poly` control is deliberately pushed high, so
/// their phase dots drift apart and realign. Pitched voices are annular
/// bands: notes are arcs (angle =
/// time, thickness = velocity, pitch a subtle radial offset — deliberately
/// not a piano roll). Upcoming material hangs ahead of the hand as dashed
/// ghosts; played notes decay as afterglow.
struct OrbitView: View {
    @ObservedObject var model: AppModel
    var side: CGFloat = 300

    @State private var clock = MotionClock()
    @State private var cache = OrbitCache()

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                draw(ctx, size: size, date: timeline.date)
            }
        }
        .frame(width: side, height: side)
        .tip("one revolution = one bar. center: drone. thin rings: standard kit. bands: bass / chords / pulse / melody; thickness = velocity.")
    }

    // Band layout as fractions of R.
    private static let droneCore: CGFloat = 0.16
    private static let drumInner: CGFloat = 0.20
    private static let drumOuter: CGFloat = 0.42
    private static let bands: [Voice: (inner: CGFloat, outer: CGFloat)] = [
        .bass: (0.45, 0.56), .chords: (0.58, 0.69),
        .pulse: (0.71, 0.81), .melody: (0.83, 0.94),
    ]
    // Practical pitch ranges (from the engine's constraint pass).
    private static let pitchRange: [Voice: ClosedRange<Double>] = [
        .bass: 24...55, .chords: 36...94, .pulse: 55...92, .melody: 55...100,
    ]
    private static let afterglowSteps = 24.0

    private func draw(_ outer: GraphicsContext, size: CGSize, date: Date) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let R = min(size.width, size.height) / 2 - 10
        let tension = model.snapshot.tension
        let t = date.timeIntervalSinceReferenceDate

        // The whole system breathes with tension — one uniform scale about
        // the center so cached geometry stays aligned with the rings.
        let breath = CGFloat(1 + tension * 0.03 * (1 + 0.5 * sin(t * 1.1)))
        var ctx = outer
        ctx.translateBy(x: c.x, y: c.y)
        ctx.scaleBy(x: breath, y: breath)
        ctx.translateBy(x: -c.x, y: -c.y)

        let displayed = clock.advance(
            playing: model.playing,
            polledBar: model.playhead.bar, polledPhase: model.playhead.phase,
            anchor: model.playheadAnchor, barDuration: model.barDuration,
            now: date)
        let steps = displayed * 16.0
        let hand = angle(forStep: steps.truncatingRemainder(dividingBy: 16))

        // Plate + tension dye: the mandala warms as the piece peaks.
        ctx.fill(Path(ellipseIn: circleRect(c, R + 4)), with: .color(Theme.weaveGround))
        ctx.fill(Path(ellipseIn: circleRect(c, R + 4)),
                 with: .radialGradient(
                    Gradient(colors: [Color(red: 0.855, green: 0.62, blue: 0.50)
                                        .opacity(0.08 + tension * 0.14), .clear]),
                    center: c, startRadius: 0, endRadius: R + 4))

        // Outer ring, step ticks (beats heavier), section progress arc.
        ctx.stroke(Path(ellipseIn: circleRect(c, R)),
                   with: .color(Theme.hairline.opacity(0.55)), lineWidth: 1)
        for s in 0..<16 {
            let a = angle(forStep: Double(s))
            let isBeat = s % 4 == 0
            let inner = R - (isBeat ? 7 : 4)
            ctx.stroke(ray(c, from: inner, to: R, angle: a),
                       with: .color(Theme.hairline.opacity(isBeat ? 0.7 : 0.4)),
                       lineWidth: isBeat ? 1.5 : 1)
        }
        let sectionFrac = (Double(model.snapshot.sectionBar) + min(1, displayed.truncatingRemainder(dividingBy: 1)))
            / Double(max(1, model.snapshot.sectionLength))
        var progress = Path()
        progress.addArc(center: c, radius: R + 3,
                        startAngle: .radians(-.pi / 2),
                        endAngle: .radians(-.pi / 2 + 2 * .pi * min(1, max(0, sectionFrac))),
                        clockwise: false)
        ctx.stroke(progress, with: .color(Theme.accent.opacity(0.30)),
                   style: StrokeStyle(lineWidth: 2, lineCap: .round))

        // Drone core: a breathing disc, deeper with tension.
        let droneActive = model.snapshot.active[.drone] ?? true
        let coreR = R * Self.droneCore * CGFloat(0.85 + 0.15 * sin(t * 0.6) * (0.4 + tension))
        ctx.fill(Path(ellipseIn: circleRect(c, coreR)),
                 with: .color(Theme.voiceColor(.drone).opacity(droneActive ? 0.30 : 0.12)))
        ctx.stroke(Path(ellipseIn: circleRect(c, coreR)),
                   with: .color(Theme.voiceColor(.drone).opacity(droneActive ? 0.65 : 0.3)),
                   lineWidth: 1.5)

        guard !model.roll.isEmpty else {
            drawEmptyRings(ctx, c: c, R: R)
            outer.draw(Text("▶  press play to weave").font(Theme.mono).foregroundColor(Theme.mid),
                       at: CGPoint(x: c.x, y: c.y + R * 0.55))
            return
        }

        // Drum rings: one per track, kick outermost. They share the bar until
        // high `poly` lets the ornament rings drift.
        let poly = model.snapshot.effectiveParams[.drums]?["poly"] ?? 0.5
        let presenceVis = 0.45 + 0.55 * model.snapshot.drumPresence
        let ringGap = R * (Self.drumOuter - Self.drumInner) / 7
        for track in DrumTrack.allCases {
            // GM percussion notes are intentionally non-contiguous; visual
            // lanes follow the track order, not the MIDI note number.
            let ringIndex = track.rawValue
            let r = R * Self.drumOuter - CGFloat(ringIndex) * ringGap
            let L = Double(DrumGenerator.effectiveLoopLength(track, poly: poly))
            ctx.stroke(Path(ellipseIn: circleRect(c, r)),
                       with: .color(Theme.hairline.opacity(0.22)), lineWidth: 0.7)
            // The ring's own phase dot: 2π · (steps mod L)/L.
            let dotA = ringAngle(steps, L)
            let dot = point(c, r, dotA)
            ctx.fill(Path(ellipseIn: CGRect(x: dot.x - 2, y: dot.y - 2, width: 4, height: 4)),
                     with: .color(Theme.voiceColor(.drums).opacity(0.35 + 0.45 * model.snapshot.drumPresence)))
        }

        // Notes from last / current / lookahead bars, timed by delta from
        // the smooth clock — everything is a pure function of (note, now).
        var beads: [(CGPoint, Voice)] = []
        for entry in model.roll {
            guard entry.bar >= model.playhead.bar - 1, entry.bar <= model.playhead.bar + 1 else { continue }
            let geo = cache.bar(entry.bar, notes: entry.notes, generation: model.rollGeneration,
                                R: R, center: c, poly: poly)

            for arc in geo.arcs {
                let delta = steps - arc.absStep
                if delta < -16 || delta > Self.afterglowSteps + arc.durSteps { continue }
                let color = Theme.voiceColor(arc.voice)
                if delta < 0 {
                    // Not yet played: threaded, waiting ahead of the hand.
                    ctx.stroke(arc.path, with: .color(Theme.voiceColorSoft(arc.voice)),
                               style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [3, 3]))
                    continue
                }
                let sounding = delta <= arc.durSteps
                let fade = sounding ? 1.0 : max(0, 1 - (delta - arc.durSteps) / Self.afterglowSteps)
                if sounding {
                    // Light-ground glow: a wider darker saturated halo.
                    ctx.stroke(arc.path, with: .color(color.opacity(0.30)),
                               style: StrokeStyle(lineWidth: arc.width + 6, lineCap: .round))
                    beads.append((point(c, arc.radius, hand), arc.voice))
                }
                ctx.stroke(arc.path, with: .color(color.opacity(arc.ink * fade)),
                           style: StrokeStyle(lineWidth: arc.width, lineCap: .round))
            }

            for knot in geo.knots {
                let delta = steps - knot.absStep
                if delta < -16 || delta > Self.afterglowSteps { continue }
                let upcoming = delta < 0
                let flare = delta >= 0 && delta < 1.5
                let fade = upcoming ? 1.0 : max(0.25, 1 - delta / Self.afterglowSteps)
                let p = point(c, knot.radius, knot.angle)
                var diamond = Path()
                let r = knot.size * (flare ? 1.4 : 1.0)
                let rx = r * (knot.wide ? 1.5 : 1.0)
                diamond.move(to: CGPoint(x: p.x - rx, y: p.y))
                diamond.addLine(to: CGPoint(x: p.x, y: p.y - r))
                diamond.addLine(to: CGPoint(x: p.x + rx, y: p.y))
                diamond.addLine(to: CGPoint(x: p.x, y: p.y + r))
                diamond.closeSubpath()
                if flare {
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - r - 3, y: p.y - r - 3,
                                                    width: (r + 3) * 2, height: (r + 3) * 2)),
                             with: .color(Theme.voiceColor(.drums).opacity(0.25 * presenceVis)))
                }
                ctx.fill(diamond, with: .color(
                    (upcoming ? Theme.voiceColorSoft(.drums) : Theme.voiceColor(.drums))
                        .opacity(knot.ink * fade * presenceVis)))
            }
        }

        // The hand, over the field but under the beads.
        ctx.stroke(ray(c, from: coreR + 3, to: R, angle: hand),
                   with: .color(Theme.text.opacity(0.5)), lineWidth: 1.5)
        let tip = point(c, R, hand)
        ctx.fill(Path(ellipseIn: CGRect(x: tip.x - 3, y: tip.y - 3, width: 6, height: 6)),
                 with: .color(Theme.accent))
        for (p, voice) in beads {
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)),
                     with: .color(Theme.voiceColor(voice)))
        }
    }

    private func drawEmptyRings(_ ctx: GraphicsContext, c: CGPoint, R: CGFloat) {
        for (_, band) in Self.bands {
            ctx.stroke(Path(ellipseIn: circleRect(c, R * (band.inner + band.outer) / 2)),
                       with: .color(Theme.hairline.opacity(0.25)), lineWidth: 1)
        }
        let ringGap = R * (Self.drumOuter - Self.drumInner) / 7
        for i in 0..<8 {
            ctx.stroke(Path(ellipseIn: circleRect(c, R * Self.drumOuter - CGFloat(i) * ringGap)),
                       with: .color(Theme.hairline.opacity(0.18)), lineWidth: 0.7)
        }
    }

    // MARK: geometry helpers

    /// 12 o'clock origin, clockwise. Canvas y grows downward, so increasing
    /// radian angles already read as clockwise on screen.
    private func angle(forStep s: Double) -> Double { -Double.pi / 2 + 2 * .pi * s / 16 }
    private func ringAngle(_ steps: Double, _ L: Double) -> Double {
        -Double.pi / 2 + 2 * .pi * (steps.truncatingRemainder(dividingBy: L)) / L
    }
    private func point(_ c: CGPoint, _ r: CGFloat, _ a: Double) -> CGPoint {
        CGPoint(x: c.x + r * CGFloat(cos(a)), y: c.y + r * CGFloat(sin(a)))
    }
    private func ray(_ c: CGPoint, from r0: CGFloat, to r1: CGFloat, angle a: Double) -> Path {
        Path { p in
            p.move(to: point(c, r0, a))
            p.addLine(to: point(c, r1, a))
        }
    }
    private func circleRect(_ c: CGPoint, _ r: CGFloat) -> CGRect {
        CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
    }

    fileprivate static func bandFor(_ v: Voice) -> (inner: CGFloat, outer: CGFloat)? { bands[v] }
    fileprivate static func rangeFor(_ v: Voice) -> ClosedRange<Double>? { pitchRange[v] }
}

// MARK: - smooth clock

/// A display clock that never jerks: it advances at nominal tempo every
/// frame and only *gently corrects* toward the scheduler's 15 Hz polled
/// position — so it can never step backward mid-play. Rewind or stop snap it.
final class MotionClock {
    private var displayed: Double = 0
    private var lastFrame: Date?

    func advance(playing: Bool, polledBar: Int, polledPhase: Double,
                 anchor: Date, barDuration: Double, now: Date) -> Double {
        let sinceAnchor = max(0, min(now.timeIntervalSince(anchor), 0.5))
        let target = Double(polledBar) + polledPhase + (playing ? sinceAnchor / barDuration : 0)
        defer { lastFrame = now }
        guard playing else { displayed = target; return displayed }
        // Rewind / reseed while playing: snap.
        if target < displayed - 0.5 { displayed = target; return displayed }
        let dtF = max(0, min(lastFrame.map { now.timeIntervalSince($0) } ?? 0, 0.1))
        var next = displayed + dtF / barDuration + (target - displayed) * min(1, 2 * dtF)
        next = min(next, target + 0.3)          // don't run away ahead
        next = max(next, max(displayed, target - 0.5))  // never backward, never lag far
        displayed = next
        return displayed
    }
}

// MARK: - cached per-bar geometry

private struct ArcGeom {
    let voice: Voice
    let path: Path
    let width: CGFloat
    let ink: Double
    let radius: CGFloat
    let absStep: Double
    let durSteps: Double
}

private struct KnotGeom {
    let radius: CGFloat
    let angle: Double
    let size: CGFloat
    let wide: Bool
    let ink: Double
    let absStep: Double
}

private struct BarOrbit {
    var arcs: [ArcGeom] = []
    var knots: [KnotGeom] = []
}

/// Arc paths are built once per bar for the current radius; each frame only
/// strokes them with time-dependent style.
private final class OrbitCache {
    private var generation = -1
    private var R: CGFloat = 0
    private var center: CGPoint = .zero
    private var poly: Double = -1
    private var bars: [Int: BarOrbit] = [:]

    func bar(_ bar: Int, notes: [NoteSummary], generation g: Int,
             R r: CGFloat, center c: CGPoint, poly p: Double) -> BarOrbit {
        if g != generation || abs(r - R) > 0.5 || abs(p - poly) > 0.01
            || abs(c.x - center.x) > 0.5 || abs(c.y - center.y) > 0.5 {
            bars.removeAll()
            generation = g
            R = r
            center = c
            poly = p
        }
        if let cached = bars[bar] { return cached }
        let geo = build(bar: bar, notes: notes)
        bars[bar] = geo
        if bars.count > 6 {
            for key in bars.keys where key < bar - 3 { bars.removeValue(forKey: key) }
        }
        return geo
    }

    private func build(bar: Int, notes: [NoteSummary]) -> BarOrbit {
        var geo = BarOrbit()
        let ringGap = R * (0.42 - 0.20) / 7
        for n in notes {
            let absStep = Double(bar) * 16 + n.startStep
            if n.voice == .drums {
                guard let track = DrumTrack.allCases.first(where: { $0.note == n.note }) else { continue }
                let L = Double(DrumGenerator.effectiveLoopLength(track, poly: poly))
                let r = R * 0.42 - CGFloat(track.rawValue) * ringGap
                let g = Double(bar) * 16 + n.startStep
                let hat = track == .hat || track == .hatOpen
                geo.knots.append(KnotGeom(
                    radius: r,
                    angle: -Double.pi / 2 + 2 * .pi * (g.truncatingRemainder(dividingBy: L)) / L,
                    size: (2 + CGFloat(n.velocity) / 127 * 3) * (hat ? 0.6 : 1),
                    wide: track == .kick,
                    ink: 0.35 + Double(n.velocity) / 127 * 0.6,
                    absStep: absStep))
                continue
            }
            guard n.voice != .drone,
                  let band = OrbitView.bandFor(n.voice),
                  let range = OrbitView.rangeFor(n.voice) else { continue }
            let frac = min(1, max(0, (Double(n.note) - range.lowerBound)
                                    / (range.upperBound - range.lowerBound)))
            let radius = R * (band.inner + (band.outer - band.inner) * CGFloat(frac))
            let a0 = -Double.pi / 2 + 2 * .pi * n.startStep / 16
            let sweep = max(2 * .pi * n.durationSteps / 16, 0.05)
            var path = Path()
            path.addArc(center: center, radius: radius,
                        startAngle: .radians(a0), endAngle: .radians(a0 + sweep),
                        clockwise: false)
            let bandWidth = (band.outer - band.inner) * R
            geo.arcs.append(ArcGeom(
                voice: n.voice, path: path,
                width: min(bandWidth * 0.6, 1.5 + CGFloat(n.velocity) / 127 * 4),
                ink: 0.5 + Double(n.velocity) / 127 * 0.4,
                radius: radius, absStep: absStep, durSteps: max(0.5, n.durationSteps)))
        }
        return geo
    }
}
