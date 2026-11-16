import MidgarCore
import SwiftUI
import TailscodeCore
import UIKit

/// Where the card's size and what it does at a turn's ending are chosen.
///
/// A card cannot be judged from a word any more than a haptic can, so this screen shows the cards
/// themselves: the real Live Activity views, drawing the same turn at each size, and the expanded
/// island a turn's ending opens. Picking one is touching the card you would rather read.
@MainActor
final class LiveActivityLookViewController: UIViewController {
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private var sizeCards: [LiveActivitySizeCard] = []
    private var endingRows: [LiveActivityEndingRow] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = LiveActivitySettings.screenTitle
        view.backgroundColor = Theme.Color.groupedBackground
        build()
        syncSelection()
    }

    private func build() {
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        view.addSubview(scroll)

        stack.axis = .vertical
        stack.spacing = Theme.Spacing.l
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.topAnchor, constant: Theme.Spacing.l),
            stack.bottomAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Theme.Spacing.xxl),
            stack.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: Theme.Spacing.l),
            stack.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -Theme.Spacing.l),
        ])

        stack.addArrangedSubview(intro())
        stack.addArrangedSubview(header(LiveActivitySettings.sizeTitle))
        let sample = CardSamples.working()
        for size in LiveActivitySize.allCases {
            let card = LiveActivitySizeCard(size: size, preview: host(LockPreview(sample: sample, size: size)))
            card.onPick = { [weak self] in self?.choose(size) }
            sizeCards.append(card)
            stack.addArrangedSubview(card)
        }
        stack.setCustomSpacing(Theme.Spacing.xl, after: sizeCards.last ?? stack)
        stack.addArrangedSubview(header(LiveActivitySettings.endingTitle))
        stack.addArrangedSubview(host(IslandPreview(sample: CardSamples.finished())))
        let rows = UIStackView()
        rows.axis = .vertical
        rows.spacing = Theme.Spacing.s
        for ending in LiveActivityEnding.allCases {
            let row = LiveActivityEndingRow(ending: ending)
            row.onPick = { [weak self] in self?.choose(ending) }
            endingRows.append(row)
            rows.addArrangedSubview(row)
        }
        stack.addArrangedSubview(rows)
        stack.addArrangedSubview(footnote())
    }

    private func intro() -> UILabel {
        let label = UILabel()
        label.font = Theme.Ramp.font(.panelDetail)
        label.textColor = Theme.Color.secondaryLabel
        label.numberOfLines = 0
        label.text = LiveActivitySettings.explanation
        return label
    }

    private func header(_ text: String) -> UILabel {
        let label = UILabel()
        label.font = Theme.Ramp.font(.cardTitle)
        label.text = text
        label.accessibilityTraits = .header
        return label
    }

    private func footnote() -> UILabel {
        let label = UILabel()
        label.font = Theme.Ramp.font(.panelFootnote)
        label.textColor = Theme.Color.secondaryLabel
        label.numberOfLines = 0
        label.textAlignment = .center
        label.text = String(
            localized:
                "The island opens only while Tailscode is not on screen, never for a chat you muted, and once per ending. An iPhone without a Dynamic Island shows the card as a banner instead, and an Apple Watch shows the chat’s name and how it ended."
        )
        return label
    }

    /// A SwiftUI preview of the real card, held as a child so it lays out and updates with the
    /// screen. The only SwiftUI here is the Live Activity's own views.
    private func host<Content: View>(_ content: Content) -> UIView {
        let hosting = UIHostingController(rootView: content)
        hosting.sizingOptions = .intrinsicContentSize
        hosting.view.backgroundColor = .clear
        hosting.view.isUserInteractionEnabled = false
        addChild(hosting)
        hosting.didMove(toParent: self)
        return hosting.view
    }

    private func choose(_ size: LiveActivitySize) {
        guard size != LiveActivitySettings.size else { return }
        LiveActivitySettings.set(size)
        HapticEngine.shared.play(.send, strength: AppPreferences.hapticIntensity)
        MidgarLog.info("Live Activity size chosen: \(size.rawValue)", category: .ui)
        AppActivityController.shared.redrawAll()
        syncSelection()
    }

    private func choose(_ ending: LiveActivityEnding) {
        guard ending != LiveActivitySettings.ending else { return }
        LiveActivitySettings.set(ending)
        HapticEngine.shared.play(.send, strength: AppPreferences.hapticIntensity)
        MidgarLog.info("Live Activity ending chosen: \(ending.rawValue)", category: .ui)
        AppActivityController.shared.reregisterAll()
        syncSelection()
    }

    private func syncSelection() {
        let size = LiveActivitySettings.size
        for card in sizeCards { card.setChosen(card.size == size) }
        let ending = LiveActivitySettings.ending
        for row in endingRows { row.setChosen(row.ending == ending) }
    }
}

/// A Lock Screen card as it will stand, on a dark wallpaper so its own ground reads.
private struct LockPreview: View {
    let sample: CardSamples.Sample
    let size: LiveActivitySize

    var body: some View {
        LockScreenCard(
            model: CardModel(
                state: sample.state, title: sample.title, server: CardSamples.server, isStale: false,
                seedKey: sample.title),
            size: size, drawsGround: true
        )
        .clipShape(RoundedRectangle(cornerRadius: LockScreenCard.corner, style: .continuous))
    }
}

/// The expanded Dynamic Island a turn's ending opens, laid out the way the system lays its regions.
struct IslandPreview: View {
    let sample: CardSamples.Sample

    var body: some View {
        let model = CardModel(
            state: sample.state, title: sample.title, server: CardSamples.server, isStale: false,
            seedKey: sample.title)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                CardOrb(model: model, size: 46)
                IslandTitle(model: model)
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 2) {
                    CardClock(model: model, font: .callout.weight(.semibold))
                    Text(model.server)
                        .font(.caption2)
                        .foregroundStyle(model.inks.dim)
                }
                .padding(.top, 4)
            }
            IslandBottom(model: model)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 44, style: .continuous))
        .environment(\.colorScheme, .dark)
    }
}

/// One size, drawn: the card at that size over its name and what it holds.
@MainActor
final class LiveActivitySizeCard: UIControl {
    let size: LiveActivitySize

    private let glass = Theme.Glass.view()
    private let name = UILabel()
    private let summary = UILabel()
    private let mark = UIImageView()

    var onPick: (() -> Void)?

    init(size: LiveActivitySize, preview: UIView) {
        self.size = size
        super.init(frame: .zero)
        build(preview)
        addTarget(self, action: #selector(picked), for: .touchUpInside)
        accessibilityTraits = .button
        isAccessibilityElement = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func build(_ preview: UIView) {
        glass.layer.cornerRadius = Theme.Radius.card
        glass.layer.cornerCurve = .continuous
        glass.clipsToBounds = true
        glass.isUserInteractionEnabled = false
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)

        name.text = size.title
        name.font = Theme.Ramp.font(.cardTitle)
        summary.text = size.explanation
        summary.font = Theme.Ramp.font(.panelDetail)
        summary.textColor = Theme.Color.secondaryLabel
        summary.numberOfLines = 0
        mark.contentMode = .scaleAspectFit
        mark.setContentHuggingPriority(.required, for: .horizontal)

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let heading = UIStackView(arrangedSubviews: [name, spacer, mark])
        heading.axis = .horizontal
        heading.alignment = .center
        heading.spacing = Theme.Spacing.s

        let column = UIStackView(arrangedSubviews: [preview, heading, summary])
        column.axis = .vertical
        column.spacing = Theme.Spacing.m
        column.isUserInteractionEnabled = false
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.m),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Spacing.l),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.m),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.m),
        ])
    }

    func setChosen(_ value: Bool) {
        mark.image = UIImage(
            systemName: value ? "checkmark.circle.fill" : "circle",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .regular))
        mark.tintColor = value ? Theme.Color.accent : Theme.Color.tertiaryLabel
        layer.borderWidth = value ? 1.5 : 0
        layer.borderColor = value ? Theme.Color.accent.cgColor : nil
        layer.cornerRadius = Theme.Radius.card
        layer.cornerCurve = .continuous
        accessibilityLabel = "\(size.title). \(size.explanation)"
        accessibilityValue = value ? String(localized: "Selected") : String(localized: "Not selected")
    }

    @objc private func picked() { onPick?() }
}

/// One way a card can greet its ending.
@MainActor
final class LiveActivityEndingRow: UIControl {
    let ending: LiveActivityEnding

    private let glass = Theme.Glass.view()
    private let name = UILabel()
    private let summary = UILabel()
    private let mark = UIImageView()

    var onPick: (() -> Void)?

    init(ending: LiveActivityEnding) {
        self.ending = ending
        super.init(frame: .zero)
        build()
        addTarget(self, action: #selector(picked), for: .touchUpInside)
        accessibilityTraits = .button
        isAccessibilityElement = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func build() {
        glass.layer.cornerRadius = Theme.Radius.card
        glass.layer.cornerCurve = .continuous
        glass.clipsToBounds = true
        glass.isUserInteractionEnabled = false
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)

        name.text = ending.title
        name.font = Theme.Ramp.font(.rowTitleStrong)
        name.numberOfLines = 0
        summary.text = ending.explanation
        summary.font = Theme.Ramp.font(.panelDetail)
        summary.textColor = Theme.Color.secondaryLabel
        summary.numberOfLines = 0
        mark.contentMode = .scaleAspectFit
        mark.setContentHuggingPriority(.required, for: .horizontal)
        mark.setContentCompressionResistancePriority(.required, for: .horizontal)

        let words = UIStackView(arrangedSubviews: [name, summary])
        words.axis = .vertical
        words.spacing = Theme.Spacing.xs
        let row = UIStackView(arrangedSubviews: [words, mark])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Theme.Spacing.m
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.m),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Spacing.m),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.l),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.l),
        ])
    }

    func setChosen(_ value: Bool) {
        mark.image = UIImage(
            systemName: value ? "checkmark.circle.fill" : "circle",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .regular))
        mark.tintColor = value ? Theme.Color.accent : Theme.Color.tertiaryLabel
        layer.borderWidth = value ? 1.5 : 0
        layer.borderColor = value ? Theme.Color.accent.cgColor : nil
        layer.cornerRadius = Theme.Radius.card
        layer.cornerCurve = .continuous
        accessibilityLabel = "\(ending.title). \(ending.explanation)"
        accessibilityValue = value ? String(localized: "Selected") : String(localized: "Not selected")
    }

    @objc private func picked() { onPick?() }
}
