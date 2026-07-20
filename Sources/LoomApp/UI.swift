import SwiftUI
import AppKit
import LoomCore

/// One warm studio-hardware surface. Neutral elevations provide structure;
/// saturation is reserved for the six MIDI identities and the ember playhead.
enum Theme {
    static let surface = Color(red: 0.847, green: 0.839, blue: 0.816)
    static let raised = Color(red: 0.890, green: 0.883, blue: 0.862)
    static let well = Color(red: 0.769, green: 0.757, blue: 0.729)
    static let weaveGround = Color(red: 0.929, green: 0.914, blue: 0.878)
    static let hairline = Color(red: 0.639, green: 0.624, blue: 0.588)

    static let text = Color(red: 0.153, green: 0.145, blue: 0.129)
    static let mid = Color(red: 0.365, green: 0.353, blue: 0.325)
    static let dim = Color(red: 0.545, green: 0.529, blue: 0.494)
    static let accent = Color(red: 0.796, green: 0.337, blue: 0.086)
    static let accentBright = Color(red: 0.918, green: 0.443, blue: 0.161)

    static let mono = Font.system(size: 11, weight: .medium, design: .monospaced)
    static let monoSmall = Font.system(size: 9.5, weight: .medium, design: .monospaced)
    static let monoBig = Font.system(size: 16, weight: .semibold, design: .monospaced)
    static let bayTitle = Font.system(size: 11, weight: .semibold, design: .monospaced)

    /// High-separation yarn colors on the warm ground. Piano-roll shapes and
    /// labels duplicate the identity so color is never the only signal.
    static func voiceColor(_ voice: Voice) -> Color {
        let (r, g, b) = voiceRGB(voice)
        return Color(red: r, green: g, blue: b)
    }

    static func voiceColorSoft(_ voice: Voice) -> Color {
        let (r, g, b) = voiceRGB(voice)
        let mix = 0.45
        return Color(red: r + (0.929 - r) * mix,
                     green: g + (0.914 - g) * mix,
                     blue: b + (0.878 - b) * mix)
    }

    static func voiceRGB(_ voice: Voice) -> (Double, Double, Double) {
        switch voice {
        case .drone:  return (0.820, 0.355, 0.030)
        case .drums:  return (0.160, 0.180, 0.205)
        case .bass:   return (0.035, 0.300, 0.720)
        case .chords: return (0.440, 0.145, 0.730)
        case .pulse:  return (0.790, 0.045, 0.340)
        case .melody: return (0.000, 0.455, 0.325)
        }
    }
}

/// The three performance macros retain physical encoders. Base and live
/// values have separate pointers so slow evolution remains visible.
struct Knob: View {
    let label: String
    @Binding var value: Double
    var ghost: Double? = nil
    var tint: Color = Theme.accent
    var help: String? = nil
    var resetValue: Double? = nil
    var diameter: CGFloat = 40
    var controlWidth: CGFloat = 62
    var tipContent: TipContent? = nil

    @State private var dragStart: Double?
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle().fill(Theme.well)
                Circle().stroke(Theme.hairline, lineWidth: 1)
                arc(to: 1, color: Theme.hairline.opacity(0.55), width: 2.5)
                arc(to: value, color: tint, width: 3)
                if let ghost, abs(ghost - value) > 0.005 {
                    pointer(at: ghost, color: tint.opacity(0.55), length: 0.28)
                }
                pointer(at: value, color: Theme.text, length: 0.44)
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { gesture in
                    if dragStart == nil { dragStart = value }
                    let fine = NSEvent.modifierFlags.contains(.shift) ? 0.2 : 1
                    value = min(1, max(0, (dragStart ?? 0)
                        - Double(gesture.translation.height) / 140 * fine))
                }
                .onEnded { _ in dragStart = nil })
            Text(hovering || dragStart != nil ? formatted(value) : label)
                .font(Theme.monoSmall).foregroundColor(Theme.mid)
                .lineLimit(1).minimumScaleFactor(0.72)
        }
        .frame(width: controlWidth)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { if let resetValue { value = resetValue } }
        .contextMenu { if let resetValue { Button("Reset \(label)") { value = resetValue } } }
        .focusable()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(formatted(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(1, value + 0.01)
            case .decrement: value = max(0, value - 0.01)
            @unknown default: break
            }
        }
        .tip(tipContent ?? TipContent(summary: help ?? label))
        .focusEffectDisabled()
    }

    private func formatted(_ value: Double) -> String {
        switch label {
        case "push": return value < 0.4 ? "space" : (value > 0.6 ? "full" : "balanced")
        case "grit": return value < 0.2 ? "pure" : (value > 0.7 ? "frayed" : "colored")
        case "evolve": return value == 0 ? "still" : String(format: "%.2f", value)
        default: return String(format: "%.2f", value)
        }
    }

    private func angle(_ value: Double) -> Angle { .degrees(-225 + value * 270) }

    private func pointer(at value: Double, color: Color, length: CGFloat) -> some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let radius = geo.size.width / 2
            let radians = angle(value).radians
            Path { path in
                path.move(to: CGPoint(x: center.x + cos(radians) * radius * (1 - length),
                                      y: center.y + sin(radians) * radius * (1 - length)))
                path.addLine(to: CGPoint(x: center.x + cos(radians) * radius * 0.88,
                                         y: center.y + sin(radians) * radius * 0.88))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        }
    }

    private func arc(to value: Double, color: Color, width: CGFloat) -> some View {
        Circle().trim(from: 0, to: CGFloat(abs(value)) * 0.75)
            .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round))
            .rotationEffect(.degrees(135)).padding(2)
    }
}

struct Rack<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(RoundedRectangle(cornerRadius: 11).fill(Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 11)
                .stroke(Theme.hairline.opacity(0.6), lineWidth: 1))
            .shadow(color: .black.opacity(0.07), radius: 3, y: 1)
    }
}

struct RackRule: View {
    var body: some View {
        Rectangle().fill(Theme.hairline.opacity(0.45)).frame(width: 1).padding(.vertical, 9)
    }
}

struct MotifStrip: View {
    let snapshot: EngineSnapshot

    var body: some View {
        HStack(spacing: 3) {
            let entries = snapshot.motifLog.suffix(24)
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(entry.isRecall ? Theme.accent
                          : (entry.cellID != nil
                             ? Theme.voiceColor(.melody).opacity(0.85)
                             : Theme.hairline.opacity(0.5)))
                    .frame(width: 7, height: entry.cellID != nil ? 14 : 5)
            }
            Spacer()
        }
        .frame(height: 16)
        .tip(TipContent(title: "motif memory",
                        summary: "One mark per recent bar: tall means a motif spoke; ember means it returned transformed.",
                        range: "low mark = rest or atmospheric phase line",
                        context: "The ring buffer holds up to eight reusable cells."))
    }
}
