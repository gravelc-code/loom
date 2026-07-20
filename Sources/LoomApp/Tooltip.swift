import SwiftUI

/// Help for a musical control. The fields deliberately describe consequence,
/// range and context instead of merely echoing the current number.
struct TipContent: Equatable {
    var title: String = ""
    var summary: String
    var range: String = ""
    var values: String = ""
    var context: String = ""

    var text: String {
        [title, summary, range, values, context]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

/// Loom's own tooltip tracker. SwiftUI redraws the orbit continuously, which
/// prevents AppKit's native hover timer from reliably firing.
@MainActor
final class TipCenter: ObservableObject {
    @Published var shown: Shown?
    @Published var last: TipContent?

    struct Shown: Equatable {
        let content: TipContent
        let at: CGPoint
        let source: CGRect
    }

    private var pending: DispatchWorkItem?
    private let delay = 0.35

    func hover(_ content: TipContent, at point: CGPoint, source: CGRect) {
        if shown != nil {
            shown = Shown(content: content, at: point, source: source)
            last = content
            return
        }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.shown = Shown(content: content, at: point, source: source)
            self?.last = content
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func leave() {
        pending?.cancel()
        pending = nil
        shown = nil
    }
}

let tipSpace = "loom.tips"

extension View {
    func tip(_ text: String) -> some View {
        modifier(TipModifier(tipContent: TipContent(summary: text)))
    }

    func tip(_ content: TipContent) -> some View {
        modifier(TipModifier(tipContent: content))
    }
}

private struct TipModifier: ViewModifier {
    let tipContent: TipContent
    @EnvironmentObject private var center: TipCenter
    @State private var sourceFrame = CGRect.zero

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .background(GeometryReader { geo in
                let frame = geo.frame(in: .named(tipSpace))
                Color.clear
                    .onAppear { sourceFrame = frame }
                    .onChange(of: frame) { _, newFrame in sourceFrame = newFrame }
            })
            .onContinuousHover(coordinateSpace: .named(tipSpace)) { phase in
                switch phase {
                case .active(let point):
                    center.hover(tipContent, at: point, source: sourceFrame)
                case .ended:
                    center.leave()
                }
            }
    }
}

/// A floating fallback for controls outside the inspector. It is positioned
/// from the source frame and never covers the control that summoned it.
struct TipOverlay: View {
    @ObservedObject var center: TipCenter
    let size: CGSize
    private let maxWidth: CGFloat = 320

    var body: some View {
        if let shown = center.shown {
            Text(shown.content.text)
                .font(Theme.monoSmall)
                .foregroundColor(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: maxWidth, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.raised)
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 3))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(Theme.hairline.opacity(0.7), lineWidth: 1))
                .position(position(for: shown))
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    private func position(for shown: TipCenter.Shown) -> CGPoint {
        let w = min(maxWidth, max(120, CGFloat(estimatedWidth)))
        let h = CGFloat(estimatedLines) * 13 + 14
        let source = shown.source
        var x = source.maxX + 12 + w / 2
        var y = source.midY
        if x + w / 2 > size.width - 8 { x = source.minX - 12 - w / 2 }
        if x - w / 2 < 8 {
            x = source.midX
            y = source.maxY + 10 + h / 2
        }
        if y + h / 2 > size.height - 8 { y = source.minY - 10 - h / 2 }
        x = min(max(x, w / 2 + 8), max(w / 2 + 8, size.width - w / 2 - 8))
        y = min(max(y, h / 2 + 8), max(h / 2 + 8, size.height - h / 2 - 8))
        return CGPoint(x: x, y: y)
    }

    private var estimatedWidth: Double {
        let chars = Double(center.shown?.content.text.count ?? 0)
        return min(Double(maxWidth), chars * 5.9 + 18)
    }

    private var estimatedLines: Int {
        let chars = Double(center.shown?.content.text.count ?? 0)
        let perLine = Double(maxWidth - 18) / 5.9
        return max(1, Int((chars / perLine).rounded(.up)))
    }
}

/// Persistent inspector help. The last useful explanation remains available
/// after the pointer leaves, so learning the instrument does not require
/// holding a hover target.
struct ContextHelpBar: View {
    @EnvironmentObject private var center: TipCenter

    var body: some View {
        let tip = center.shown?.content ?? center.last
        VStack(alignment: .leading, spacing: 2) {
            Text(tip?.title.isEmpty == false ? tip!.title : "hover a control")
                .font(Theme.bayTitle).foregroundColor(Theme.text)
            Text(tip.map { [$0.summary, $0.range, $0.values, $0.context]
                .filter { !$0.isEmpty }.joined(separator: "  ·  ") }
                 ?? "Purpose, audible range, live modulation and context appear here.")
                .font(Theme.monoSmall).foregroundColor(Theme.mid)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
    }
}
