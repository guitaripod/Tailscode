import TailscodeCore
import UIKit

/// Why a feature is in beta, as a sheet sized to its words with a large detent behind it for the
/// type sizes that outgrow it. Every word is the catalog's; this arranges them and draws a button
/// that puts the report on the pasteboard.
@MainActor
final class BetaCardViewController: UIViewController {
    private static let detent = UISheetPresentationController.Detent.Identifier("beta.card")
    private static let copiedFor: Duration = .milliseconds(1500)

    private let feature: BetaFeature
    private let freshness: BetaFreshness
    private let reportLines: () -> [String]
    private let scroll = UIScrollView()
    private let column = UIStackView()
    private var copyButton: UIButton?
    private var copiedTicket = 0

    /// Opens the card for a feature, leading with what changed when the person last looked at an
    /// older version, and marks the card seen at this version so the mark settles.
    static func present(feature: BetaFeature, reportLines: @escaping () -> [String], from presenter: UIViewController) {
        let freshness = BetaSeenStore.freshness(feature, current: BetaEnvironment.appVersion)
        let card = BetaCardViewController(feature: feature, freshness: freshness, reportLines: reportLines)
        card.loadViewIfNeeded()
        let fallbackWidth = presenter.view.bounds.width
        let bottom = presenter.view.safeAreaInsets.bottom
        if let sheet = card.sheetPresentationController {
            sheet.prefersGrabberVisible = true
            sheet.detents = [
                .custom(identifier: detent) { [weak card] context in
                    guard let card else { return context.maximumDetentValue }
                    let width = card.view.bounds.width > 0 ? card.view.bounds.width : fallbackWidth
                    return min(context.maximumDetentValue, card.fittingHeight(width: width, bottomInset: bottom))
                },
                .large(),
            ]
        }
        presenter.present(card, animated: true)
        BetaSeenStore.markSeen(feature, at: BetaEnvironment.appVersion)
        AppLogger.ui.info("beta card opened feature=\(feature.rawValue) freshness=\(String(describing: freshness))")
    }

    private init(feature: BetaFeature, freshness: BetaFreshness, reportLines: @escaping () -> [String]) {
        self.feature = feature
        self.freshness = freshness
        self.reportLines = reportLines
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.groupedBackground
        scroll.alwaysBounceVertical = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        column.axis = .vertical
        column.alignment = .fill
        column.spacing = Theme.Spacing.m
        column.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(column)
        build()
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            column.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Theme.Spacing.xl),
            column.bottomAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Theme.Spacing.s),
            column.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: Theme.Spacing.l),
            column.trailingAnchor.constraint(
                equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -Theme.Spacing.l),
        ])
    }

    /// The height the words need at this width, so the sheet is exactly as tall as what it says.
    func fittingHeight(width: CGFloat, bottomInset: CGFloat) -> CGFloat {
        let inner = max(width - 2 * Theme.Spacing.l, 200)
        let content = column.systemLayoutSizeFitting(
            CGSize(width: inner, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        return ceil(content.height + Theme.Spacing.xl + Theme.Spacing.s + bottomInset)
    }

    private func build() {
        let card = feature.card
        column.addArrangedSubview(heading(card))
        column.addArrangedSubview(body(card.lead, ink: Theme.Color.secondaryLabel))
        if freshness == .changed, !card.changes.isEmpty {
            column.addArrangedSubview(since(card.changes))
        }
        for paragraph in card.paragraphs {
            column.addArrangedSubview(body(paragraph, ink: Theme.Color.label))
        }
        if !card.works.isEmpty {
            column.addArrangedSubview(list(BetaWords.solid, lines: card.works, symbol: "checkmark.circle.fill", tone: .live))
        }
        if !card.rough.isEmpty {
            column.addArrangedSubview(list(BetaWords.rough, lines: card.rough, symbol: "circle.dotted", tone: .attention))
        }
        let actions = buttons()
        column.addArrangedSubview(actions)
        if let before = column.arrangedSubviews.dropLast().last {
            column.setCustomSpacing(Theme.Spacing.l, after: before)
        }
    }

    private func heading(_ card: BetaCard) -> UIView {
        let mark = BetaBadge(feature: feature, reportLines: { [] }, interactive: false)
        let title = UILabel()
        title.text = card.title
        title.font = Theme.Ramp.font(.panelTitle)
        title.adjustsFontForContentSizeCategory = true
        title.numberOfLines = 0
        title.accessibilityTraits = .header
        let stack = UIStackView(arrangedSubviews: [mark, title])
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Spacing.s
        return stack
    }

    private func body(_ text: String, ink: UIColor) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = Theme.Ramp.font(.cardBody)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = ink
        label.numberOfLines = 0
        return label
    }

    private func heading(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = Theme.Ramp.font(.panelLabel)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = Theme.Color.label
        label.numberOfLines = 0
        label.accessibilityTraits = .header
        return label
    }

    private func since(_ changes: [BetaChange]) -> UIView {
        let stack = UIStackView(arrangedSubviews: [heading(BetaWords.sinceYouLastLooked)])
        stack.axis = .vertical
        stack.spacing = Theme.Spacing.xs
        for change in changes {
            stack.addArrangedSubview(body(change.line, ink: Theme.Color.label))
        }
        return stack
    }

    private func list(_ title: String, lines: [String], symbol: String, tone: ActivityTone) -> UIView {
        let stack = UIStackView(arrangedSubviews: [heading(title)])
        stack.axis = .vertical
        stack.spacing = Theme.Spacing.xs
        stack.isAccessibilityElement = false
        for line in lines {
            stack.addArrangedSubview(row(line, symbol: symbol, tone: tone))
        }
        return stack
    }

    private func row(_ line: String, symbol: String, tone: ActivityTone) -> UIView {
        let glyph = UIImageView(
            image: UIImage(
                systemName: symbol,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)))
        glyph.tintColor = tone.color
        glyph.contentMode = .center
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        glyph.setContentCompressionResistancePriority(.required, for: .horizontal)
        glyph.isAccessibilityElement = false
        let text = body(line, ink: Theme.Color.label)
        let stack = UIStackView(arrangedSubviews: [glyph, text])
        stack.axis = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = Theme.Spacing.s
        glyph.widthAnchor.constraint(equalToConstant: 18).isActive = true
        return stack
    }

    private func buttons() -> UIView {
        var copy = UIButton.Configuration.gray()
        copy.title = BetaWords.copyReport
        copy.cornerStyle = .large
        copy.baseForegroundColor = Theme.Color.label
        copy.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
        let copyButton = UIButton(configuration: copy, primaryAction: UIAction { [weak self] _ in self?.copyReport() })
        copyButton.titleLabel?.adjustsFontForContentSizeCategory = true
        self.copyButton = copyButton
        var done = UIButton.Configuration.filled()
        done.title = BetaWords.gotIt
        done.baseBackgroundColor = Theme.Color.special
        done.baseForegroundColor = Theme.Color.onAccent
        done.cornerStyle = .large
        done.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
        let doneButton = UIButton(configuration: done, primaryAction: UIAction { [weak self] _ in
            Theme.Haptics.tap()
            self?.dismiss(animated: true)
        })
        doneButton.titleLabel?.adjustsFontForContentSizeCategory = true
        let stack = UIStackView(arrangedSubviews: [copyButton, doneButton])
        stack.axis = .vertical
        stack.spacing = Theme.Spacing.s
        return stack
    }

    private func copyReport() {
        let report = BetaReport.compose(
            feature: feature, app: BetaEnvironment.appLine, system: BetaEnvironment.systemLine, lines: reportLines())
        UIPasteboard.general.string = report
        Theme.Haptics.success()
        AppLogger.ui.info("beta report copied feature=\(feature.rawValue) chars=\(report.count)")
        UIAccessibility.post(notification: .announcement, argument: BetaWords.reportCopied)
        copiedTicket += 1
        let ticket = copiedTicket
        setCopyTitle(BetaWords.reportCopied)
        Task { [weak self] in
            try? await Task.sleep(for: Self.copiedFor)
            guard let self, self.copiedTicket == ticket else { return }
            self.setCopyTitle(BetaWords.copyReport)
        }
    }

    private func setCopyTitle(_ title: String) {
        copyButton?.configuration?.title = title
    }
}
