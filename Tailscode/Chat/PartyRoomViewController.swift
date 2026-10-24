import TailscodeCore
import UIKit

/// Putting a model in the party from anywhere: the first hollow slot takes it and a toast says
/// which; with six full nothing moves until the person says which one makes room.
@MainActor
enum PartyAdding {
    static func add(
        _ preset: ModelPreset, cards: () -> [PartyCard], from presenter: UIViewController,
        say: @escaping (String) -> Void
    ) {
        switch ModelParty.place(preset) {
        case .placed(let slot):
            Theme.Haptics.success()
            say(String(localized: "Added to slot \(slot + 1)"))
        case .full:
            Theme.Haptics.tap()
            let room = PartyRoomViewController(cards: cards()) { slot in
                ModelParty.replace(slot: slot, with: preset)
                Theme.Haptics.success()
                say(String(localized: "Added to slot \(slot + 1)"))
            }
            room.modalPresentationStyle = .pageSheet
            if let sheet = room.sheetPresentationController {
                sheet.detents = [.medium(), .large()]
                sheet.prefersGrabberVisible = true
                sheet.preferredCornerRadius = 32
            }
            presenter.present(room, animated: true)
        }
    }
}

/// "Which one makes room?": the six slots as a compact list, each a ball's colour, its name and
/// what it runs, and a press on one puts the new model there.
@MainActor
final class PartyRoomViewController: UIViewController {
    private let cards: [PartyCard]
    private let onChoose: (Int) -> Void

    init(cards: [PartyCard], onChoose: @escaping (Int) -> Void) {
        self.cards = cards
        self.onChoose = onChoose
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        if #available(iOS 26.0, *) {
            view.backgroundColor = .clear
        } else {
            view.backgroundColor = Theme.Color.groupedBackground
        }
        let title = UILabel()
        title.text = String(localized: "Which one makes room?")
        title.font = PartyCardView.font(20, .bold)
        title.adjustsFontForContentSizeCategory = true
        title.textColor = Theme.Color.label
        title.numberOfLines = 0
        title.accessibilityTraits = .header
        let list = UIStackView(arrangedSubviews: [title] + cards.map(row))
        list.axis = .vertical
        list.spacing = Theme.Spacing.s
        list.setCustomSpacing(Theme.Spacing.m, after: title)
        list.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(list)
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            list.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 28),
            list.bottomAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Theme.Spacing.l),
            list.leadingAnchor.constraint(
                equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: Theme.Spacing.xl),
            list.trailingAnchor.constraint(
                equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -Theme.Spacing.xl),
        ])
    }

    private func row(for card: PartyCard) -> UIView {
        var config = UIButton.Configuration.plain()
        config.title = card.title
        config.subtitle = card.machine.map { card.subtitle + " · " + String(localized: "on \($0)") }
            ?? card.subtitle
        config.titleAlignment = .leading
        config.titleLineBreakMode = .byWordWrapping
        config.subtitleLineBreakMode = .byWordWrapping
        config.baseForegroundColor = Theme.Color.label
        config.image = EffortMeterView.dotImage(
            card.chip.map { Theme.Color.modelIdentity($0) } ?? Theme.Color.tertiaryLabel)
        config.imagePadding = Theme.Spacing.m
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
        config.background.backgroundColor = Theme.Color.secondaryBackground
        config.background.cornerRadius = 14
        let button = UIButton(configuration: config)
        button.contentHorizontalAlignment = .leading
        button.accessibilityLabel = card.spoken
        button.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                let slot = card.slot
                self.dismiss(animated: true) { self.onChoose(slot) }
            }, for: .touchUpInside)
        return button
    }
}
