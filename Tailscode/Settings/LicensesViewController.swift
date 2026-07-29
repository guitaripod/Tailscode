import SafariServices
import UIKit

/// Attribution for everything linked into the app. Tailscode is GPL-3.0, which
/// obliges it to name what it builds on and to say where the source is.
@MainActor
final class LicensesViewController: UIViewController {
    private struct Package: Hashable {
        let name: String
        let license: String
        let url: String
    }

    private enum Section: Int, CaseIterable {
        case tailscode, apple, thirdParty

        var title: String {
            switch self {
            case .tailscode: return "Tailscode"
            case .apple: return String(localized: "Apple Open Source")
            case .thirdParty: return String(localized: "Third Party")
            }
        }
    }

    private static let tailscode: [Package] = [
        Package(
            name: "Tailscode", license: "GPL-3.0",
            url: "https://github.com/guitaripod/Tailscode"),
        Package(
            name: "CodingAgentKit", license: "GPL-3.0",
            url: "https://github.com/guitaripod/CodingAgentKit"),
    ]

    /// The SwiftNIO/async-http-client stack CodingAgentKit's transport pulls in.
    /// Every one of these ships under Apache 2.0.
    private static let apple: [Package] = [
        Package(name: "async-http-client", license: "Apache-2.0", url: "https://github.com/swift-server/async-http-client"),
        Package(name: "swift-algorithms", license: "Apache-2.0", url: "https://github.com/apple/swift-algorithms"),
        Package(name: "swift-argument-parser", license: "Apache-2.0", url: "https://github.com/apple/swift-argument-parser"),
        Package(name: "swift-asn1", license: "Apache-2.0", url: "https://github.com/apple/swift-asn1"),
        Package(name: "swift-async-algorithms", license: "Apache-2.0", url: "https://github.com/apple/swift-async-algorithms"),
        Package(name: "swift-atomics", license: "Apache-2.0", url: "https://github.com/apple/swift-atomics"),
        Package(name: "swift-certificates", license: "Apache-2.0", url: "https://github.com/apple/swift-certificates"),
        Package(name: "swift-collections", license: "Apache-2.0", url: "https://github.com/apple/swift-collections"),
        Package(name: "swift-configuration", license: "Apache-2.0", url: "https://github.com/apple/swift-configuration"),
        Package(name: "swift-crypto", license: "Apache-2.0", url: "https://github.com/apple/swift-crypto"),
        Package(name: "swift-distributed-tracing", license: "Apache-2.0", url: "https://github.com/apple/swift-distributed-tracing"),
        Package(name: "swift-docc-plugin", license: "Apache-2.0", url: "https://github.com/apple/swift-docc-plugin"),
        Package(name: "swift-docc-symbolkit", license: "Apache-2.0", url: "https://github.com/swiftlang/swift-docc-symbolkit"),
        Package(name: "swift-http-structured-headers", license: "Apache-2.0", url: "https://github.com/apple/swift-http-structured-headers"),
        Package(name: "swift-http-types", license: "Apache-2.0", url: "https://github.com/apple/swift-http-types"),
        Package(name: "swift-log", license: "Apache-2.0", url: "https://github.com/apple/swift-log"),
        Package(name: "swift-nio", license: "Apache-2.0", url: "https://github.com/apple/swift-nio"),
        Package(name: "swift-nio-extras", license: "Apache-2.0", url: "https://github.com/apple/swift-nio-extras"),
        Package(name: "swift-nio-http2", license: "Apache-2.0", url: "https://github.com/apple/swift-nio-http2"),
        Package(name: "swift-nio-ssl", license: "Apache-2.0", url: "https://github.com/apple/swift-nio-ssl"),
        Package(name: "swift-nio-transport-services", license: "Apache-2.0", url: "https://github.com/apple/swift-nio-transport-services"),
        Package(name: "swift-numerics", license: "Apache-2.0", url: "https://github.com/apple/swift-numerics"),
        Package(name: "swift-service-context", license: "Apache-2.0", url: "https://github.com/apple/swift-service-context"),
        Package(name: "swift-service-lifecycle", license: "Apache-2.0", url: "https://github.com/swift-server/swift-service-lifecycle"),
        Package(name: "swift-system", license: "Apache-2.0", url: "https://github.com/apple/swift-system"),
    ]

    private static let thirdParty: [Package] = [
        Package(name: "EventSource", license: "MIT", url: "https://github.com/mattt/EventSource")
    ]

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Package>!

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Acknowledgements")
        view.backgroundColor = Theme.Color.groupedBackground
        configure()
        applySnapshot()
    }

    private func configure() {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        config.footerMode = .supplementary
        let layout = UICollectionViewCompositionalLayout.list(using: config)
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        view.addSubview(collectionView)

        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, Package> {
            cell, _, package in
            var content = cell.defaultContentConfiguration()
            content.text = package.name
            content.secondaryText = package.license
            content.prefersSideBySideTextAndSecondaryText = true
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }

        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { view, _, indexPath in
            var content = UIListContentConfiguration.header()
            content.text = Section(rawValue: indexPath.section)?.title
            view.contentConfiguration = content
        }

        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { view, _, indexPath in
            guard Section(rawValue: indexPath.section) == .tailscode else {
                view.contentConfiguration = nil
                return
            }
            var content = UIListContentConfiguration.footer()
            content.text = String(
                localized:
                    "Tailscode is free software under the GNU General Public License v3. You are entitled to the complete source, which is linked above."
            )
            view.contentConfiguration = content
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, package in
            collectionView.dequeueConfiguredReusableCell(
                using: cell, for: indexPath, item: package)
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            let registration = kind == UICollectionView.elementKindSectionFooter ? footer : header
            return collectionView.dequeueConfiguredReusableSupplementary(
                using: registration, for: indexPath)
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Package>()
        snapshot.appendSections(Section.allCases)
        snapshot.appendItems(Self.tailscode, toSection: .tailscode)
        snapshot.appendItems(Self.apple, toSection: .apple)
        snapshot.appendItems(Self.thirdParty, toSection: .thirdParty)
        dataSource.apply(snapshot, animatingDifferences: false)
    }
}

extension LicensesViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let package = dataSource.itemIdentifier(for: indexPath),
            let url = URL(string: package.url)
        else { return }
        present(SFSafariViewController(url: url), animated: true)
    }
}
