import SwiftUI
import CoreGraphics
import LoomCore

/// The reaction-diffusion field made legible: the simulation crossfades
/// between its per-bar states so the worms visibly crawl, the two probe
/// points that feed the modulation matrix are marked on the image, and each
/// probe's live value drives a labeled meter naming the parameters it
/// pushes. The engine's drift made visible, not a lava lamp.
///
/// Structure note: every `.help` sits *outside* the animating TimelineView
/// that owns it. A tooltip re-applied each frame never survives long enough
/// for macOS's hover timer to fire.
struct FieldView: View {
    @ObservedObject var field: FieldModel
    let isPlaying: () -> Bool
    let barDuration: () -> Double
    var side: CGFloat = 130

    /// Probe positions + routings, mirroring ModulationEngine.
    struct Probe {
        let x: Double, y: Double
        let label: String
        let color: Color
        let help: String
    }
    static let probes: [Probe] = [
        Probe(x: 0.23, y: 0.31, label: "ghost · chord register", color: Theme.accent,
              help: "probe 1 — sampled every bar: it bends drum ghost-note activity and the pad's register. Discrete switches never move behind your back."),
        Probe(x: 0.71, y: 0.62, label: "density · gate · register",
              color: Theme.voiceColor(.bass),
              help: "probe 2 — sampled every bar: it bends kit density, pulse gate, and melody register. It moves continuous color while rhythm choices remain explicit."),
    ]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            FieldCanvas(field: field, isPlaying: isPlaying, barDuration: barDuration)
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(Theme.hairline.opacity(0.5), lineWidth: 1))
                .tip("a Gray-Scott reaction-diffusion simulation advancing with the music — deterministic from the seed, so the same seed drifts the same way. The two marked crosshairs are the probe points sampled into the modulation matrix.")

            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(Self.probes.enumerated()), id: \.offset) { _, probe in
                    ProbeMeter(field: field, isPlaying: isPlaying, barDuration: barDuration, probe: probe)
                        .tip(probe.help)
                }
                Text("gray-scott field · probes feed the mod matrix")
                    .font(Theme.monoSmall)
                    .foregroundColor(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .tip("the field is loom's slow organic drift: local chemical rules producing patterns that never exactly repeat, sampled as modulation so the music inherits that wandering")
                Spacer(minLength: 0)
            }
            .frame(width: 172)
        }
    }
}

/// One probe's live value as a labeled meter.
private struct ProbeMeter: View {
    @ObservedObject var field: FieldModel
    let isPlaying: () -> Bool
    let barDuration: () -> Double
    let probe: FieldView.Probe

    var body: some View {
        // 20 fps is plenty for a field that crawls a few pixels per bar.
        TimelineView(.periodic(from: .now, by: 1.0 / 20.0)) { timeline in
            let v = FieldMath.sample(FieldMath.blend(field, playing: isPlaying(), barDuration: barDuration(), at: timeline.date),
                                     x: probe.x, y: probe.y)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(probe.color)
                        .frame(width: 6, height: 6)
                    Text(probe.label)
                        .font(Theme.monoSmall)
                        .foregroundColor(Theme.mid)
                        .lineLimit(1)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.well)
                        Capsule().fill(probe.color.opacity(0.85))
                            .frame(width: max(3, geo.size.width * CGFloat((v + 1) / 2)))
                    }
                }
                .frame(height: 5)
            }
        }
    }
}

/// The crawling image with its probe crosshairs.
private struct FieldCanvas: View {
    @ObservedObject var field: FieldModel
    let isPlaying: () -> Bool
    let barDuration: () -> Double

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 20.0)) { timeline in
            let grid = FieldMath.blend(field, playing: isPlaying(), barDuration: barDuration(), at: timeline.date)
            Canvas { ctx, size in
                if let img = FieldMath.image(from: grid) {
                    ctx.draw(Image(decorative: img, scale: 1).interpolation(.medium),
                             in: CGRect(origin: .zero, size: size))
                }
                for probe in FieldView.probes {
                    let p = CGPoint(x: size.width * probe.x, y: size.height * probe.y)
                    let v = FieldMath.sample(grid, x: probe.x, y: probe.y)   // -1…1
                    let r: CGFloat = 5 + CGFloat(v + 1) * 2.5
                    ctx.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r,
                                                      width: r * 2, height: r * 2)),
                               with: .color(probe.color), lineWidth: 1.5)
                    var cross = Path()
                    cross.move(to: CGPoint(x: p.x - r - 3, y: p.y))
                    cross.addLine(to: CGPoint(x: p.x - r + 2, y: p.y))
                    cross.move(to: CGPoint(x: p.x + r - 2, y: p.y))
                    cross.addLine(to: CGPoint(x: p.x + r + 3, y: p.y))
                    cross.move(to: CGPoint(x: p.x, y: p.y - r - 3))
                    cross.addLine(to: CGPoint(x: p.x, y: p.y - r + 2))
                    cross.move(to: CGPoint(x: p.x, y: p.y + r - 2))
                    cross.addLine(to: CGPoint(x: p.x, y: p.y + r + 3))
                    ctx.stroke(cross, with: .color(probe.color.opacity(0.8)), lineWidth: 1)
                }
            }
        }
    }
}

@MainActor
private enum FieldMath {
    /// Crossfade the last two per-bar grids by time-since-arrival so the
    /// simulation appears to advance continuously.
    static func blend(_ field: FieldModel, playing: Bool, barDuration: Double,
                      at date: Date) -> [Float] {
        let curr = field.curr
        let prev = field.prev
        guard curr.count == Field.size * Field.size else { return [] }
        guard prev.count == curr.count, playing else { return curr }
        let phase = Float(min(1, max(0, date.timeIntervalSince(field.stamp) / barDuration)))
        var out = [Float](repeating: 0, count: curr.count)
        for i in 0..<curr.count { out[i] = prev[i] + (curr[i] - prev[i]) * phase }
        return out
    }

    /// Parchment → sienna → deep ember. Punchier than a linear ramp so the
    /// worms read on the light theme.
    static func image(from grid: [Float]) -> CGImage? {
        let s = Field.size
        guard grid.count == s * s else { return nil }
        var pixels = [UInt8](repeating: 0, count: s * s * 4)
        for i in 0..<(s * s) {
            let x = min(1, max(0, grid[i] * 3.2))
            let r, g, b: Float
            if x < 0.55 {
                let t = x / 0.55
                r = 239 + (203 - 239) * t
                g = 233 + (112 - 233) * t
                b = 222 + (44 - 222) * t
            } else {
                let t = (x - 0.55) / 0.45
                r = 203 + (66 - 203) * t
                g = 112 + (32 - 112) * t
                b = 44 + (14 - 44) * t
            }
            pixels[i * 4 + 0] = UInt8(r)
            pixels[i * 4 + 1] = UInt8(g)
            pixels[i * 4 + 2] = UInt8(b)
            pixels[i * 4 + 3] = 255
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &pixels, width: s, height: s, bitsPerComponent: 8,
                                  bytesPerRow: s * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        return ctx.makeImage()
    }

    /// Bilinear sample normalized to [-1, 1] — the same contract as
    /// `Field.sample`, applied to the blended grid.
    static func sample(_ grid: [Float], x: Double, y: Double) -> Double {
        let s = Field.size
        guard grid.count == s * s else { return 0 }
        let fx = x.truncatingRemainder(dividingBy: 1) * Double(s)
        let fy = y.truncatingRemainder(dividingBy: 1) * Double(s)
        let x0 = Int(fx) % s, y0 = Int(fy) % s
        let x1 = (x0 + 1) % s, y1 = (y0 + 1) % s
        let tx = Float(fx - fx.rounded(.down)), ty = Float(fy - fy.rounded(.down))
        let a = grid[y0 * s + x0] * (1 - tx) + grid[y0 * s + x1] * tx
        let b = grid[y1 * s + x0] * (1 - tx) + grid[y1 * s + x1] * tx
        let val = a * (1 - ty) + b * ty
        return Double(min(1, max(-1, val * 5 - 1)))
    }
}
