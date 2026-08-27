import UIKit

/// A bar pinned edge to edge is right on a phone and wrong on a big window, where it
/// stretches past anything a hand or an eye can use. The rail gives a view two sets of
/// horizontal pins — the window's edges in compact width, the readable column in regular —
/// and swaps them as the window's own size class changes, so the composer and its chrome
/// stay aligned with the lists, which follow the same readable column through their layout.
@MainActor
final class ReadableRail {
    private let compact: [NSLayoutConstraint]
    private let regular: [NSLayoutConstraint]

    convenience init(_ view: UIView, in host: UIView) {
        self.init(
            host: host,
            compact: [
                view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            ],
            regular: [
                view.leadingAnchor.constraint(equalTo: host.readableContentGuide.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: host.readableContentGuide.trailingAnchor),
            ])
    }

    init(host: UIView, compact: [NSLayoutConstraint], regular: [NSLayoutConstraint]) {
        self.compact = compact
        self.regular = regular
        host.registerForTraitChanges([UITraitHorizontalSizeClass.self]) {
            [weak self] (traited: UIView, _) in
            self?.apply(traited.traitCollection)
        }
        apply(host.traitCollection)
    }

    private func apply(_ traits: UITraitCollection) {
        let wide = traits.horizontalSizeClass == .regular
        NSLayoutConstraint.deactivate(wide ? compact : regular)
        NSLayoutConstraint.activate(wide ? regular : compact)
    }
}

extension UICollectionViewCompositionalLayout {
    /// The list layout every screen uses, kept to the readable column once the window is
    /// regular-width — a row that spans a 13-inch window is a line nobody can read.
    static func readableList(
        using config: UICollectionLayoutListConfiguration
    ) -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { _, environment in
            let section = NSCollectionLayoutSection.list(
                using: config, layoutEnvironment: environment)
            if environment.traitCollection.horizontalSizeClass == .regular {
                section.contentInsetsReference = .readableContent
            }
            return section
        }
    }
}
