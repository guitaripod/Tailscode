import TailscodeCore
import UIKit

/// The card as it will leave, before it leaves. Sharing a picture nobody has seen is a guess, so
/// the share sheet is reached through this: the card drawn at the chosen look, a picker that
/// redraws it the moment another look is picked, and one Share. The choice is remembered for
/// next time; nothing on the analytics screen changes, because the look dresses the card only.
final class ShareCardViewController: UIViewController {
    private let share: AnalyticsShare
    private let scroll = UIScrollView()
    private let preview = UIImageView()
    private let stylePicker = UIButton(configuration: .tinted())
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var previewHeight: NSLayoutConstraint?
    private var style = CardStyleSelection.current
    private var renderGeneration = 0

    init(analytics: UsageAnalytics) {
        self.share = AnalyticsShare(analytics)
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Share card")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    static func present(_ analytics: UsageAnalytics, from presenter: UIViewController) {
        let card = ShareCardViewController(analytics: analytics)
        let navigation = UINavigationController(rootViewController: card)
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        presenter.present(navigation, animated: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.background
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .close,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localized: "Share"), image: UIImage(systemName: "square.and.arrow.up"),
            primaryAction: UIAction { [weak self] _ in self?.shareTapped() })
        navigationItem.rightBarButtonItem?.style = .done

        stylePicker.configuration?.cornerStyle = .capsule
        stylePicker.configuration?.imagePadding = 8
        stylePicker.showsMenuAsPrimaryAction = true
        stylePicker.changesSelectionAsPrimaryAction = true
        stylePicker.menu = styleMenu()
        stylePicker.translatesAutoresizingMaskIntoConstraints = false
        dressPicker()

        scroll.alwaysBounceVertical = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        preview.contentMode = .scaleAspectFit
        preview.layer.cornerRadius = Theme.Radius.card
        preview.layer.cornerCurve = .continuous
        preview.clipsToBounds = true
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.accessibilityLabel = String(localized: "Card preview")
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true

        view.addSubview(stylePicker)
        view.addSubview(scroll)
        scroll.addSubview(preview)
        view.addSubview(spinner)
        let height = preview.heightAnchor.constraint(equalToConstant: 0)
        previewHeight = height
        NSLayoutConstraint.activate([
            stylePicker.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Theme.Spacing.m),
            stylePicker.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: Theme.Spacing.l),
            stylePicker.trailingAnchor.constraint(
                lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor,
                constant: -Theme.Spacing.l),
            scroll.topAnchor.constraint(equalTo: stylePicker.bottomAnchor, constant: Theme.Spacing.m),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            preview.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            preview.leadingAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: Theme.Spacing.l),
            preview.trailingAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -Theme.Spacing.l),
            preview.bottomAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Theme.Spacing.xl),
            preview.widthAnchor.constraint(
                equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -2 * Theme.Spacing.l),
            height,
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        renderPreview()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        fitPreview()
    }

    private func styleMenu() -> UIMenu {
        let actions = CardStyle.all.map { candidate in
            UIAction(
                title: candidate.name, subtitle: candidate.tagline,
                image: AnalyticsCardRenderer.swatch(candidate),
                state: candidate.id == style.id ? .on : .off
            ) { [weak self] _ in self?.pick(candidate) }
        }
        return UIMenu(title: String(localized: "Card style"), children: actions)
    }

    private func pick(_ candidate: CardStyle) {
        guard candidate.id != style.id else { return }
        style = candidate
        CardStyleSelection.set(candidate)
        Theme.Haptics.selection()
        dressPicker()
        renderPreview()
    }

    private func dressPicker() {
        stylePicker.configuration?.title = style.name
        stylePicker.configuration?.image = AnalyticsCardRenderer.swatch(style, size: 18)
        stylePicker.accessibilityLabel = String(localized: "Card style: \(style.name)")
    }

    /// The preview is drawn at the card's own logical size, which is a quarter of the pixels the
    /// share will carry and every one of its words; a share sheet waits on the full render.
    private func renderPreview() {
        renderGeneration += 1
        let generation = renderGeneration
        let share = share
        let style = style
        let dark = traitCollection.userInterfaceStyle == .dark
        spinner.startAnimating()
        Task.detached(priority: .userInitiated) {
            let rendered = AnalyticsCardRenderer.png(share, scale: 1, dark: dark, style: style)
            let image = rendered.flatMap { UIImage(data: $0.data) }
            await MainActor.run { [weak self] in
                guard let self, generation == self.renderGeneration else { return }
                self.spinner.stopAnimating()
                self.preview.image = image
                self.fitPreview()
            }
        }
    }

    private func fitPreview() {
        guard let image = preview.image, image.size.width > 0 else { return }
        let width = scroll.frameLayoutGuide.layoutFrame.width - 2 * Theme.Spacing.l
        previewHeight?.constant = (width * image.size.height / image.size.width).rounded()
    }

    private func shareTapped() {
        var items: [Any] = [share.plainText]
        if let url = AnalyticsCardRenderer.temporaryFile(share, style: style) {
            items.insert(url, at: 0)
        }
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        sheet.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        sheet.popoverPresentationController?.sourceView = view
        Theme.Haptics.success()
        present(sheet, animated: true)
    }
}
