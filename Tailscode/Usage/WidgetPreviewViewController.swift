#if DEBUG
    import SwiftUI
    import UIKit
    import WidgetKit

    /// Renders the Home Screen widget families at their real point sizes so layouts can be
    /// screenshot and verified on a simulator (widgets themselves can't be added headlessly).
    /// `--widget-preview` shows the full multi-provider entry; `--widget-preview-alt` shows
    /// the variants that entry can't exercise (single provider, two providers, empty).
    final class WidgetPreviewViewController: UIViewController {
        private let alt: Bool

        init(alt: Bool) {
            self.alt = alt
            super.init(nibName: nil, bundle: nil)
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            title = alt ? "Widget Preview · Alt" : "Widget Preview"
            view.backgroundColor = UIColor.systemGray5
            let host = UIHostingController(rootView: WidgetPreviewGrid(alt: alt))
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
        let alt: Bool
        private let entry = UsageWidgetStore.read() ?? UsageWidgetStore.previewEntry()

        private var singleEntry: UsageWidgetEntry {
            var copy = entry
            copy.providers = Array(entry.providers.prefix(1))
            return copy
        }

        private var pairEntry: UsageWidgetEntry {
            var copy = entry
            copy.providers = Array(entry.providers.prefix(2))
            return copy
        }

        private var emptyEntry: UsageWidgetEntry {
            UsageWidgetEntry(date: entry.date, providers: [], isStale: false)
        }

        var body: some View {
            ScrollView {
                VStack(spacing: 10) {
                    if alt {
                        tile(pairEntry, 338, 354) { LargeUsageView(entry: pairEntry) }
                        tile(singleEntry, 338, 158) { MediumUsageView(entry: singleEntry) }
                        HStack(spacing: 12) {
                            tile(singleEntry, 158, 158) { SmallUsageView(entry: singleEntry) }
                            tile(emptyEntry, 158, 158) { SmallUsageView(entry: emptyEntry) }
                        }
                    } else {
                        tile(entry, 338, 354) { LargeUsageView(entry: entry) }
                        tile(entry, 338, 158) { MediumUsageView(entry: entry) }
                        HStack(spacing: 12) {
                            tile(entry, 158, 158) { SmallUsageView(entry: entry) }
                            VStack(spacing: 12) {
                                tile(entry, 158, 72) { AccessoryRectangularView(entry: entry).foregroundStyle(.primary) }
                                tile(entry, 158, 72) { AccessoryCircularView(entry: entry).foregroundStyle(.primary) }
                            }
                        }
                    }
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
            }
        }

        private func tile(_ entry: UsageWidgetEntry, _ width: CGFloat, _ height: CGFloat, @ViewBuilder _ content: () -> some View) -> some View {
            ZStack {
                ContainerBackdrop(entry: entry)
                content().padding(16)
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.black.opacity(0.12)))
        }
    }
#endif
