import SwiftUI
import AppKit

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case text, bars, rings
    var id: Self { self }
    var title: String {
        switch self {
        case .text: return "Text"
        case .bars: return "Bars"
        case .rings: return "Rings"
        }
    }
}

enum MenuBarMetrics: String, CaseIterable, Identifiable {
    case session, weekly, both
    var id: Self { self }
    var title: String {
        switch self {
        case .session: return "5h"
        case .weekly: return "Weekly"
        case .both: return "Both"
        }
    }
    /// Index into ProviderUsage.metrics: 0 = 5h session, 1 = weekly (Claude and Codex).
    var indices: [Int] {
        switch self {
        case .session: return [0]
        case .weekly: return [1]
        case .both: return [0, 1]
        }
    }
}

enum MenuBarKeys {
    static let style = "menuBarStyle"
    static let metrics = "menuBarMetrics"
    static let showPercent = "menuBarShowPercent"
    static let colored = "menuBarColored"
}

struct MenuBarItem {
    let symbol: String
    let metrics: [UsageMetric?]

    var percentText: String {
        let values = metrics.map { $0?.percent.map { "\(Int($0.rounded()))" } ?? "–" }
        return values.joined(separator: "/") + (values.allSatisfy { $0 == "–" } ? "" : "%")
    }
}

struct MenuBarLabel: View {
    @ObservedObject var store: UsageStore
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(MenuBarKeys.style) private var style = MenuBarStyle.rings
    @AppStorage(MenuBarKeys.metrics) private var metrics = MenuBarMetrics.session
    @AppStorage(MenuBarKeys.showPercent) private var showPercent = true
    @AppStorage(MenuBarKeys.colored) private var colored = true

    private var items: [MenuBarItem] {
        let providers = [("✳︎", store.snapshot?.claude), ("›_", store.snapshot?.codex)]
        return providers.compactMap { symbol, usage in
            guard usage?.isEnabled != false else { return nil }
            let values = metrics.indices.map { index in
                usage.flatMap { $0.metrics.indices.contains(index) ? $0.metrics[index] : nil }
            }
            return MenuBarItem(symbol: symbol, metrics: values)
        }
    }

    var body: some View {
        if style == .text || items.isEmpty {
            Text(items.isEmpty ? "✳︎" : items.map { "\($0.symbol) \($0.percentText)" }.joined(separator: "  "))
        } else {
            Image(nsImage: renderedGauge)
        }
    }

    // MenuBarExtra labels only display Text/Image, so the gauge is drawn into an image.
    private var renderedGauge: NSImage {
        let gauge = MenuBarGauge(items: items, style: style, showPercent: showPercent, colored: colored)
            .environment(\.colorScheme, colorScheme)
        let renderer = ImageRenderer(content: gauge)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        // Template images are tinted by macOS to match the menu bar, like system icons.
        image.isTemplate = !colored
        return image
    }
}

struct MenuBarGauge: View {
    let items: [MenuBarItem]
    let style: MenuBarStyle
    let showPercent: Bool
    let colored: Bool

    private var ink: Color { colored ? .primary : .black }
    private var track: Color { colored ? Color.primary.opacity(0.22) : Color.black.opacity(0.3) }
    private func fill(_ metric: UsageMetric?) -> Color { colored ? (metric?.color ?? .secondary) : .black }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                HStack(spacing: 3) {
                    Text(item.symbol).font(.system(size: 11, weight: .semibold))
                    if style == .rings { rings(item.metrics) } else { bars(item.metrics) }
                    if showPercent {
                        Text(item.percentText).font(.system(size: 11, weight: .medium).monospacedDigit())
                    }
                }
            }
        }
        .foregroundStyle(ink)
        .frame(height: 18)
        .padding(.horizontal, 1)
    }

    private func bars(_ metrics: [UsageMetric?]) -> some View {
        let width: CGFloat = 26
        return VStack(spacing: 2) {
            ForEach(metrics.indices, id: \.self) { index in
                let metric = metrics[index]
                Capsule().fill(track)
                    .overlay(alignment: .leading) {
                        Capsule().fill(fill(metric)).frame(width: width * (metric?.fraction ?? 0))
                    }
                    .frame(width: width, height: metrics.count > 1 ? 4 : 6)
            }
        }
    }

    private func rings(_ metrics: [UsageMetric?]) -> some View {
        ZStack {
            ForEach(metrics.indices, id: \.self) { index in
                ring(metrics[index], diameter: index == 0 ? 16 : 8)
            }
        }
        .frame(width: 16, height: 16)
    }

    private func ring(_ metric: UsageMetric?, diameter: CGFloat) -> some View {
        let lineWidth: CGFloat = 2.5
        return ZStack {
            Circle().inset(by: lineWidth / 2).stroke(track, lineWidth: lineWidth)
            Circle().inset(by: lineWidth / 2)
                .trim(from: 0, to: metric?.fraction ?? 0)
                .stroke(fill(metric), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: diameter, height: diameter)
    }
}
