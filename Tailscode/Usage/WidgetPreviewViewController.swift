#if DEBUG
    import SwiftUI
    import TailscodeCore
    import UIKit
    import WidgetKit

    /// Renders the widget families at their real point sizes so layouts can be screenshot and
    /// verified on a simulator (widgets themselves can't be added headlessly).
    /// `--widget-preview` shows the full multi-provider entry at every Home Screen size;
    /// `--widget-preview-alt` shows what that entry can't exercise — one provider, a wall, a prepaid
    /// balance, nothing stored — plus the Lock Screen accessories.
    final class WidgetPreviewViewController: UIViewController {
        /// One screen holds about two Home Screen families at their real size, so the previews are
        /// split into three passes rather than one scroll nobody can screenshot past.
        enum Mode: String {
            case home
            case states
            case lock

            static func from(arguments: [String]) -> Mode {
                if arguments.contains("--widget-preview-alt") { return .states }
                if arguments.contains("--widget-preview-lock") { return .lock }
                return .home
            }

            var title: String {
                switch self {
                case .home: return "Widget Preview · Home"
                case .states: return "Widget Preview · States"
                case .lock: return "Widget Preview · Lock"
                }
            }
        }

        private let mode: Mode

        init(mode: Mode) {
            self.mode = mode
            super.init(nibName: nil, bundle: nil)
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            title = mode.title
            view.backgroundColor = Theme.Color.assistantBubble
            let host = UIHostingController(rootView: WidgetPreviewGrid(mode: mode))
            host.view.backgroundColor = .clear
            addChild(host)
            host.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.topAnchor.constraint(equalTo: view.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
            host.didMove(toParent: self)
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    }

    private struct WidgetPreviewGrid: View {
        let mode: WidgetPreviewViewController.Mode
        @Environment(\.colorScheme) private var colorScheme

        private let stored = UsageWidgetStore.read() ?? UsageWidgetStore.previewEntry()

        private func entry(
            _ snapshot: UsageWidgetEntry, grouping: WidgetGrouping = .automatic,
            detail: WidgetDetail = .automatic, accent: WidgetAccentChoice = .theme
        ) -> UsageEntry {
            UsageEntry(
                date: Date(),
                glance: snapshot.glance(grouping: grouping, detail: detail),
                accent: accent, showsReset: true)
        }

        private func trimmed(_ count: Int) -> UsageWidgetEntry {
            var copy = stored
            copy.providers = Array(stored.providers.prefix(count))
            return copy
        }

        /// A provider at its wall, which is the state every size has to be legible in and the one a
        /// live snapshot almost never shows.
        private var walled: UsageWidgetEntry {
            var copy = trimmed(1)
            copy.providers = copy.providers.map { provider in
                var out = provider
                out.gauges = provider.gauges.enumerated().map { index, gauge in
                    guard index == 0 else { return gauge }
                    var full = gauge
                    full.fraction = 1
                    full.percentText = String(localized: "Used up")
                    return full
                }
                return out
            }
            return copy
        }

        private var balanceOnly: UsageWidgetEntry {
            var copy = stored
            copy.providers = stored.providers.filter { $0.gauges.contains { $0.limitUSD == nil && $0.usedUSD != nil } }
            return copy.providers.isEmpty ? trimmed(1) : copy
        }

        private var empty: UsageWidgetEntry {
            UsageWidgetEntry(date: stored.date, providers: [], isStale: false)
        }

        var body: some View {
            ScrollView {
                VStack(spacing: 10) {
                    switch mode {
                    case .home:
                        label("Every provider · large")
                        tile(entry(stored), 338, 354) { LargeUsageView(entry: $0, palette: $1) }
                        label("Medium · automatic, then compact in provider colours")
                        tile(entry(stored), 338, 158) { MediumUsageView(entry: $0, palette: $1) }
                        tile(entry(stored, detail: .compact, accent: .provider), 338, 158) {
                            MediumUsageView(entry: $0, palette: $1)
                        }
                    case .states:
                        label("Small · automatic, tightest-first, at the wall, balance")
                        HStack(spacing: 12) {
                            tile(entry(stored), 158, 158) { SmallUsageView(entry: $0, palette: $1) }
                            tile(entry(stored, grouping: .hottest), 158, 158) {
                                SmallUsageView(entry: $0, palette: $1)
                            }
                        }
                        HStack(spacing: 12) {
                            tile(entry(walled), 158, 158) { SmallUsageView(entry: $0, palette: $1) }
                            tile(entry(balanceOnly), 158, 158) {
                                SmallUsageView(entry: $0, palette: $1)
                            }
                        }
                        label("At the wall · medium, and nothing stored")
                        tile(entry(walled), 338, 158) { MediumUsageView(entry: $0, palette: $1) }
                        HStack(spacing: 12) {
                            tile(entry(empty), 158, 158) { SmallUsageView(entry: $0, palette: $1) }
                            tile(entry(empty), 158, 158) { MediumUsageView(entry: $0, palette: $1) }
                        }
                    case .lock:
                        label("One provider · detailed")
                        tile(entry(trimmed(1), detail: .detailed), 338, 354) {
                            LargeUsageView(entry: $0, palette: $1)
                        }
                        label("Lock Screen")
                        HStack(spacing: 12) {
                            accessory(entry(stored), 158, 72) { AccessoryRectangularView(entry: $0) }
                            accessory(entry(stored), 76, 76) { AccessoryCircularView(entry: $0) }
                            accessory(entry(walled), 76, 76) { AccessoryCircularView(entry: $0) }
                        }
                        accessory(entry(stored), 250, 40) { AccessoryInlineView(entry: $0) }
                    }
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
            }
        }

        private func label(_ text: String) -> some View {
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
        }

        private func palette(_ entry: UsageEntry) -> WidgetPalette {
            WidgetPalette.resolve(
                choice: entry.accent, dark: colorScheme == .dark, mode: .fullColor)
        }

        private func tile(
            _ entry: UsageEntry, _ width: CGFloat, _ height: CGFloat,
            @ViewBuilder _ content: (UsageEntry, WidgetPalette) -> some View
        ) -> some View {
            let palette = palette(entry)
            return ZStack {
                ContainerBackdrop(glance: entry.glance, palette: palette)
                content(entry, palette).padding(16)
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.12)))
        }

        private func accessory(
            _ entry: UsageEntry, _ width: CGFloat, _ height: CGFloat,
            @ViewBuilder _ content: (UsageEntry) -> some View
        ) -> some View {
            ZStack {
                Color.black.opacity(0.55)
                content(entry).foregroundStyle(.white).padding(8)
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
#endif
