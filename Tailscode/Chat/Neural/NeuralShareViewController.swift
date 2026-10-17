import TailscodeCore
import UIKit

/// A settled turn as it will leave, before it leaves: the poster drawn at the chosen look, a
/// picker that redraws it the moment another look is picked, and Share and Copy. Sharing a picture
/// nobody has seen is a guess, so the share sheet is reached through this, the way the analytics
/// card's is; the sheet is the system's own, which carries Save Image, Copy and Files, so the
/// picture reaches Photos and the pasteboard by the road every other picture in the app takes.
///
/// The poster says only what the transcript can prove, so what is drawn here is exactly what is
/// sent: the same geometry (`NeuralShare.Card`), the hero drawn from the same turn the stage shows.
final class NeuralShareViewController: UIViewController {
    private let turn: NeuralTurn
    private let prompt: String
    private let scroll = UIScrollView()
    private let preview = UIImageView()
    private let lookPicker = UIButton(configuration: .tinted())
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var previewHeight: NSLayoutConstraint?
    private var look: CardStyle
    private var renderGeneration = 0
    private var shareItem: UIBarButtonItem?

    init(turn: NeuralTurn, prompt: String, look: CardStyle = .app) {
        self.turn = turn
        self.prompt = prompt
        self.look = look
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Share this turn")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    static func present(
        turn: NeuralTurn, prompt: String, look: CardStyle = .app, from presenter: UIViewController
    ) {
        let share = NeuralShareViewController(turn: turn, prompt: prompt, look: look)
        let navigation = UINavigationController(rootViewController: share)
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
        let share = UIBarButtonItem(
            title: String(localized: "Share"), image: UIImage(systemName: "square.and.arrow.up"),
            primaryAction: UIAction { [weak self] _ in self?.shareTapped() })
        share.style = .done
        let copy = UIBarButtonItem(
            title: String(localized: "Copy"), image: UIImage(systemName: "doc.on.doc"),
            primaryAction: UIAction { [weak self] _ in self?.copyTapped() })
        navigationItem.rightBarButtonItems = [share, copy]
        shareItem = share

        lookPicker.configuration?.cornerStyle = .capsule
        lookPicker.configuration?.imagePadding = 8
        lookPicker.showsMenuAsPrimaryAction = true
        lookPicker.changesSelectionAsPrimaryAction = true
        lookPicker.menu = lookMenu()
        lookPicker.translatesAutoresizingMaskIntoConstraints = false
        dressPicker()

        scroll.alwaysBounceVertical = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        preview.contentMode = .scaleAspectFit
        preview.layer.cornerRadius = Theme.Radius.card
        preview.layer.cornerCurve = .continuous
        preview.clipsToBounds = true
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.isAccessibilityElement = true
        preview.accessibilityLabel = NeuralReading.spoken(turn)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true

        view.addSubview(lookPicker)
        view.addSubview(scroll)
        scroll.addSubview(preview)
        view.addSubview(spinner)
        let height = preview.heightAnchor.constraint(equalToConstant: 0)
        previewHeight = height
        NSLayoutConstraint.activate([
            lookPicker.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Theme.Spacing.m),
            lookPicker.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: Theme.Spacing.l),
            lookPicker.trailingAnchor.constraint(
                lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor,
                constant: -Theme.Spacing.l),
            scroll.topAnchor.constraint(equalTo: lookPicker.bottomAnchor, constant: Theme.Spacing.m),
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
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

    private var isDark: Bool { traitCollection.userInterfaceStyle == .dark }

    private func lookMenu() -> UIMenu {
        let actions = NeuralShare.looks.map { candidate in
            UIAction(
                title: candidate.name, subtitle: candidate.tagline,
                image: AnalyticsCardRenderer.swatch(candidate, traits: traitCollection),
                state: candidate.id == look.id ? .on : .off
            ) { [weak self] _ in self?.pick(candidate) }
        }
        return UIMenu(title: String(localized: "Card style"), children: actions)
    }

    private func pick(_ candidate: CardStyle) {
        guard candidate.id != look.id else { return }
        look = candidate
        Theme.Haptics.selection()
        dressPicker()
        renderPreview()
    }

    private func dressPicker() {
        lookPicker.configuration?.title = look.name
        lookPicker.configuration?.image = AnalyticsCardRenderer.swatch(
            look, size: 18, traits: traitCollection)
        lookPicker.accessibilityLabel = String(localized: "Card style: \(look.name)")
    }

    /// The poster at its own logical size, with a hero drawn for it. The hero is the GPU's and so
    /// is drawn here on the main actor; the painting of the poster around it is not.
    private func renderPreview() {
        renderGeneration += 1
        let generation = renderGeneration
        spinner.startAnimating()
        let turn = turn
        let prompt = prompt
        let look = look
        let dark = isDark
        let hero = Self.hero(for: turn, look: look, dark: dark, width: NeuralShare.Card.heroWidth)
        Task.detached(priority: .userInitiated) {
            let image = NeuralShareRenderer.image(
                turn: turn, prompt: prompt, look: look, dark: dark, hero: hero, scale: 1)
            await MainActor.run { [weak self] in
                guard let self, generation == self.renderGeneration else { return }
                self.spinner.stopAnimating()
                self.preview.image = image
                self.fitPreview()
            }
        }
    }

    private static func hero(for turn: NeuralTurn, look: CardStyle, dark: Bool, width: Double)
        -> UIImage
    {
        let palette = NeuralShare.headPalette(style: look, dark: dark)
        let model = NeuralBrainModel(turn: turn)
        return NeuralShareHero.render(
            model: model, palette: palette, size: NeuralShareHero.size(width: CGFloat(width)))
    }

    private func fitPreview() {
        guard let image = preview.image, image.size.width > 0 else { return }
        let width = scroll.frameLayoutGuide.layoutFrame.width - 2 * Theme.Spacing.l
        previewHeight?.constant = (width * image.size.height / image.size.width).rounded()
    }

    /// The poster at the size it is sent, which is twice the preview and carries a hero drawn at
    /// twice the width.
    private func sentImage() -> UIImage {
        let hero = Self.hero(
            for: turn, look: look, dark: isDark, width: NeuralShare.Card.heroWidth * 2)
        return NeuralShareRenderer.image(
            turn: turn, prompt: prompt, look: look, dark: isDark, hero: hero, scale: 2)
    }

    private func shareTapped() {
        let hero = Self.hero(
            for: turn, look: look, dark: isDark, width: NeuralShare.Card.heroWidth * 2)
        var items: [Any] = [NeuralReading.spoken(turn)]
        if let url = NeuralShareRenderer.temporaryFile(
            turn: turn, prompt: prompt, look: look, dark: isDark, hero: hero)
        {
            items.insert(url, at: 0)
        }
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        sheet.popoverPresentationController?.barButtonItem = shareItem
        Theme.Haptics.success()
        present(sheet, animated: true)
    }

    private func copyTapped() {
        UIPasteboard.general.image = sentImage()
        Theme.Haptics.success()
        AppLogger.ui.info("turn poster copied")
    }
}
