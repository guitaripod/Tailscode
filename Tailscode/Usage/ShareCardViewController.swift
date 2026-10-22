import TailscodeCore
import UIKit

/// The picture as it will leave, before it leaves. Sharing a picture nobody has seen is a guess,
/// so the system share sheet, Photos and the pasteboard are all reached through this: the format
/// (a post X shows whole, a square, a portrait, the full-length column), a chip for every module
/// the account can fill and the reason beside every one it cannot, the look, and the picture
/// itself, redrawn a moment after anything changes. The choice is remembered per device; nothing
/// on the analytics screen changes, because the share dresses the picture only.
final class ShareCardViewController: UIViewController {
    private static let redrawDelay: Duration = .milliseconds(120)
    private static let wideBreakpoint: CGFloat = 700
    private static let landscapeBreakpoint: CGFloat = 560
    private static let inset = Theme.Spacing.l

    private let analytics: UsageAnalytics
    private let package: AnalyticsShare

    private let previewPane = UIView()
    private let previewScroll = UIScrollView()
    private let preview = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let controls = UIScrollView()
    private let column = UIStackView()
    private let formatSegments: UISegmentedControl
    private let formatMenu = UIButton(configuration: .tinted())
    private let tagline = UILabel()
    private let note = UILabel()
    private let stylePicker = UIButton(configuration: .tinted())
    private var chips: [ShareModule: ShareChipButton] = [:]
    private var actionButtons: [UIButton] = []
    private let actionBar = UIStackView()
    private let actionRule = UIView()

    private var redrawTask: Task<Void, Never>?
    private var generation = 0
    private var renderedWidth: CGFloat = 0
    private var exported: (key: ExportKey, data: Data, filename: String)?
    private var isExporting = false

    private(set) var selection: ShareSelection
    private(set) var previewImage: UIImage?

    private struct ExportKey: Equatable {
        let selection: ShareSelection
        let dark: Bool
        let scale: CGFloat
    }

    init(analytics: UsageAnalytics, selection: ShareSelection = ShareSelectionStore.load()) {
        self.analytics = analytics
        self.package = AnalyticsShare(analytics)
        self.selection = selection
        formatSegments = UISegmentedControl(items: ShareFormat.allCases.map(\.title))
        super.init(nibName: nil, bundle: nil)
        title = Localized.text("Share card")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    static func present(_ analytics: UsageAnalytics, from presenter: UIViewController) {
        let card = ShareCardViewController(analytics: analytics)
        let navigation = UINavigationController(rootViewController: card)
        if presenter.traitCollection.userInterfaceIdiom == .pad {
            navigation.modalPresentationStyle = .formSheet
            navigation.preferredContentSize = CGSize(width: 760, height: 720)
        } else if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        presenter.present(navigation, animated: true)
    }

    var fit: ShareFit { selection.fit(analytics) }

    var caption: String { package.caption(selection) }

    var altText: String { package.altText(selection) }

    func isEnabled(_ module: ShareModule) -> Bool { chips[module]?.isEnabled ?? false }

    func isOn(_ module: ShareModule) -> Bool { chips[module]?.isOn ?? false }

    var noteText: String? { note.isHidden ? nil : note.text }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.background
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .close,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: Localized.text("Share"), image: UIImage(systemName: "square.and.arrow.up"),
            primaryAction: UIAction { [weak self] _ in self?.shareTapped() })
        navigationItem.rightBarButtonItem?.style = .done

        buildPreview()
        buildControls()
        view.addSubview(previewPane)
        view.addSubview(controls)
        buildActionBar()
        view.addSubview(actionRule)
        view.addSubview(spinner)
        dressActionBar()
        spinner.hidesWhenStopped = true
        refreshControls()
        scheduleRedraw(immediately: true)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self]) {
            (self: Self, _) in
            self.dressPicker()
            self.dressPreviewBorder()
            self.scheduleRedraw(immediately: true)
        }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.dressFormatControl()
            self.dressActionBar()
            self.view.setNeedsLayout()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || isMovingFromParent { redrawTask?.cancel() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPanes()
        layoutPreview()
        let target = previewTargetWidth()
        if renderedWidth > 0, abs(target - renderedWidth) / renderedWidth > 0.12 {
            scheduleRedraw()
        }
    }

    private func buildPreview() {
        previewScroll.alwaysBounceVertical = false
        previewScroll.showsVerticalScrollIndicator = false
        previewScroll.contentInsetAdjustmentBehavior = .never
        previewPane.addSubview(previewScroll)
        previewScroll.addSubview(preview)
        preview.contentMode = .scaleAspectFit
        preview.layer.cornerRadius = Theme.Radius.card
        preview.layer.cornerCurve = .continuous
        preview.layer.borderWidth = 1
        dressPreviewBorder()
        preview.clipsToBounds = true
        preview.isAccessibilityElement = true
        preview.accessibilityTraits = .image
    }

    private func dressPreviewBorder() {
        preview.layer.borderColor = Theme.Color.separator.resolvedColor(with: traitCollection).cgColor
    }

    private func buildControls() {
        controls.alwaysBounceVertical = true
        controls.contentInsetAdjustmentBehavior = .never
        controls.addSubview(column)
        column.axis = .vertical
        column.spacing = Theme.Spacing.l
        column.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(
                equalTo: controls.contentLayoutGuide.topAnchor, constant: Theme.Spacing.m),
            column.bottomAnchor.constraint(
                equalTo: controls.contentLayoutGuide.bottomAnchor, constant: -Theme.Spacing.xl),
            column.leadingAnchor.constraint(
                equalTo: controls.frameLayoutGuide.leadingAnchor, constant: Self.inset),
            column.trailingAnchor.constraint(
                equalTo: controls.frameLayoutGuide.trailingAnchor, constant: -Self.inset),
            column.widthAnchor.constraint(
                equalTo: controls.frameLayoutGuide.widthAnchor, constant: -2 * Self.inset),
        ])
        column.addArrangedSubview(formatSection())
        column.addArrangedSubview(moduleSection())
        column.addArrangedSubview(lookSection())
    }

    private func heading(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = Theme.Ramp.font(.sectionLabel)
        label.textColor = Theme.Color.secondaryLabel
        label.numberOfLines = 0
        label.accessibilityTraits = .header
        return label
    }

    private func section(_ title: String, _ views: [UIView]) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: [heading(title)] + views)
        stack.axis = .vertical
        stack.spacing = Theme.Spacing.s
        return stack
    }

    private func formatSection() -> UIView {
        formatSegments.addAction(
            UIAction { [weak self] _ in
                guard let self,
                    ShareFormat.allCases.indices.contains(self.formatSegments.selectedSegmentIndex)
                else { return }
                self.choose(ShareFormat.allCases[self.formatSegments.selectedSegmentIndex])
            }, for: .valueChanged)
        formatMenu.configuration?.cornerStyle = .capsule
        formatMenu.showsMenuAsPrimaryAction = true
        formatMenu.changesSelectionAsPrimaryAction = true
        formatMenu.contentHorizontalAlignment = .leading
        tagline.font = Theme.Ramp.font(.panelFootnote)
        tagline.textColor = Theme.Color.secondaryLabel
        tagline.numberOfLines = 0
        tagline.isAccessibilityElement = false
        return section(Localized.text("Format"), [formatSegments, formatMenu, tagline])
    }

    private func moduleSection() -> UIView {
        let buttons = ShareModule.selectable.map { module -> ShareChipButton in
            let chip = ShareChipButton(module: module)
            chip.addAction(UIAction { [weak self] _ in self?.press(module) }, for: .touchUpInside)
            chips[module] = chip
            return chip
        }
        note.font = Theme.Ramp.font(.panelFootnote)
        note.textColor = Theme.Color.secondaryLabel
        note.numberOfLines = 0
        note.isHidden = true
        return section(Localized.text("Modules"), [ShareFlowView(items: buttons), note])
    }

    private func lookSection() -> UIView {
        stylePicker.configuration?.cornerStyle = .capsule
        stylePicker.configuration?.imagePadding = Theme.Spacing.s
        stylePicker.showsMenuAsPrimaryAction = true
        stylePicker.changesSelectionAsPrimaryAction = true
        stylePicker.contentHorizontalAlignment = .leading
        stylePicker.heightAnchor.constraint(
            greaterThanOrEqualToConstant: ShareFlowView.minimumHit
        ).isActive = true
        stylePicker.menu = styleMenu()
        dressPicker()
        return section(Localized.text("Card style"), [stylePicker])
    }

    private func buildActionBar() {
        actionButtons = [
            actionButton(Localized.text("Save to Photos"), "photo.badge.arrow.down") {
                [weak self] in self?.saveToPhotos()
            },
            actionButton(Localized.text("Copy image"), "doc.on.doc") { [weak self] in
                self?.copyImage()
            },
            actionButton(Localized.text("Copy caption"), "text.quote") { [weak self] in
                self?.copyCaption()
            },
        ]
        actionBar.axis = .horizontal
        actionBar.distribution = .fillEqually
        actionBar.alignment = .fill
        actionBar.spacing = Theme.Spacing.s
        for button in actionButtons { actionBar.addArrangedSubview(button) }
        actionRule.backgroundColor = Theme.Color.separator
    }

    /// At ordinary sizes Save and Copy are pinned under the controls; at an accessibility size
    /// three of them side by side would eat the screen, so they become the last rows of the list.
    private func dressActionBar() {
        let inline = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        actionBar.removeFromSuperview()
        actionRule.isHidden = inline
        actionBar.axis = inline ? .vertical : .horizontal
        actionBar.distribution = inline ? .fill : .fillEqually
        for button in actionButtons {
            button.configuration?.imagePlacement = inline ? .leading : .top
        }
        if inline {
            column.addArrangedSubview(actionBar)
        } else {
            view.insertSubview(actionBar, belowSubview: spinner)
        }
        view.setNeedsLayout()
    }

    private func actionButton(
        _ title: String, _ symbol: String, _ handler: @escaping () -> Void
    ) -> UIButton {
        var config = UIButton.Configuration.tinted()
        config.cornerStyle = .large
        config.title = title
        config.image = UIImage(systemName: symbol)
        config.imagePlacement = .top
        config.imagePadding = Theme.Spacing.xs
        config.contentInsets = NSDirectionalEdgeInsets(
            top: Theme.Spacing.s, leading: Theme.Spacing.xs, bottom: Theme.Spacing.s,
            trailing: Theme.Spacing.xs)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var attributes = $0
            attributes.font = Theme.Ramp.font(.control)
            return attributes
        }
        let button = UIButton(configuration: config)
        button.addAction(UIAction { _ in handler() }, for: .touchUpInside)
        return button
    }

    private var usesFormatMenu: Bool {
        traitCollection.preferredContentSizeCategory > .large
    }

    private func dressFormatControl() {
        formatSegments.isHidden = usesFormatMenu
        formatMenu.isHidden = !usesFormatMenu
        formatMenu.menu = UIMenu(
            title: Localized.text("Format"),
            children: ShareFormat.allCases.map { format in
                UIAction(
                    title: format.title, subtitle: format.tagline,
                    image: UIImage(systemName: format.symbolName),
                    state: format == selection.format ? .on : .off
                ) { [weak self] _ in self?.choose(format) }
            })
        formatMenu.configuration?.title = selection.format.title
        formatMenu.configuration?.image = UIImage(systemName: selection.format.symbolName)
        formatMenu.configuration?.imagePadding = Theme.Spacing.s
    }

    private func styleMenu() -> UIMenu {
        let actions = CardStyle.all.map { candidate in
            UIAction(
                title: candidate.name, subtitle: candidate.tagline,
                image: AnalyticsCardRenderer.swatch(candidate, traits: traitCollection),
                state: candidate.id == selection.style.id ? .on : .off
            ) { [weak self] _ in self?.pick(candidate) }
        }
        return UIMenu(title: Localized.text("Card style"), children: actions)
    }

    private func dressPicker() {
        stylePicker.menu = styleMenu()
        stylePicker.configuration?.title = selection.style.name
        stylePicker.configuration?.image = AnalyticsCardRenderer.swatch(
            selection.style, size: 18, traits: traitCollection)
        stylePicker.accessibilityLabel = Localized.text("Card style: %@", selection.style.name)
    }

    func choose(_ format: ShareFormat) {
        guard format != selection.format else { return }
        selection.format = format
        selection.style = CardStyleSelection.current(for: format)
        Theme.Haptics.selection()
        remember()
        refreshControls()
        scheduleRedraw()
    }

    func press(_ module: ShareModule) {
        let outcome = selection.toggle(module, in: analytics)
        remember()
        refreshControls()
        if case .refused(let reason) = outcome {
            Theme.Haptics.warning()
            show(note: reason)
            UIAccessibility.post(notification: .announcement, argument: reason)
            return
        }
        Theme.Haptics.selection()
        scheduleRedraw()
    }

    private func pick(_ candidate: CardStyle) {
        guard candidate.id != selection.style.id else { return }
        selection.style = candidate
        CardStyleSelection.set(candidate)
        Theme.Haptics.selection()
        dressPicker()
        remember()
        scheduleRedraw()
    }

    private func remember() {
        ShareSelectionStore.save(selection)
    }

    private func show(note text: String?) {
        guard let text, !text.isEmpty else {
            note.isHidden = true
            note.text = nil
            return
        }
        note.text = text
        note.isHidden = false
    }

    private func refreshControls() {
        let current = fit
        formatSegments.selectedSegmentIndex =
            ShareFormat.allCases.firstIndex(of: selection.format) ?? 0
        tagline.text = selection.format.tagline
        dressFormatControl()
        for module in ShareModule.selectable {
            chips[module]?.apply(
                current.state(of: module), unavailable: current.unavailable[module] != nil)
        }
        dressPicker()
        show(note: current.note)
        preview.accessibilityLabel = altText
    }

    private var isDark: Bool { traitCollection.userInterfaceStyle == .dark }

    /// What the picture is asked to be in the box it will be shown in, in points: the width the
    /// column gives it, or the width at which its whole height still shows.
    private func previewTargetWidth() -> CGFloat {
        let box = previewBox()
        guard box.width > 0, box.height > 0 else { return 0 }
        guard let height = selection.format.canvasHeight else { return box.width }
        let aspect = CGFloat(height / selection.format.canvasWidth)
        return min(box.width, box.height / aspect)
    }

    private func previewBox() -> CGSize {
        CGSize(
            width: previewPane.bounds.width - 2 * Self.inset,
            height: previewPane.bounds.height - 2 * Self.inset)
    }

    /// The card is drawn at the pixels it will be seen at (never past 2x), so the preview is the
    /// file's own picture at the size of the glass, not a smaller one stretched.
    private func previewScale() -> CGFloat {
        let width = previewTargetWidth()
        guard width > 0 else { return 1 }
        let pixels = width * traitCollection.displayScale
        return max(0.5, min(2, pixels / CGFloat(selection.format.canvasWidth)))
    }

    private func scheduleRedraw(immediately: Bool = false) {
        redrawTask?.cancel()
        generation += 1
        let mine = generation
        redrawTask = Task { [weak self] in
            if !immediately { try? await Task.sleep(for: Self.redrawDelay) }
            guard !Task.isCancelled, let self else { return }
            await self.renderPreview(generation: mine)
        }
    }

    private func renderPreview(generation mine: Int) async {
        guard isViewLoaded else { return }
        let scale = previewScale()
        let target = previewTargetWidth()
        let selection = selection
        let share = package
        let dark = isDark
        spinner.startAnimating()
        let image = await Task.detached(priority: .userInitiated) {
            AnalyticsCardRenderer.image(share.card(selection, dark: dark), scale: scale)
        }.value
        guard mine == generation, !Task.isCancelled else { return }
        spinner.stopAnimating()
        renderedWidth = target
        setPreview(image)
    }

    private func setPreview(_ image: UIImage) {
        let swap = { [self] in
            preview.image = image
            previewImage = image
            layoutPreview()
        }
        guard preview.image != nil, !UIAccessibility.isReduceMotionEnabled else {
            swap()
            return
        }
        UIView.transition(
            with: preview, duration: 0.15, options: [.transitionCrossDissolve, .allowUserInteraction],
            animations: swap)
    }

    private func layoutPanes() {
        let safe = view.bounds.inset(by: view.safeAreaInsets)
        defer {
            spinner.center = CGPoint(x: previewPane.frame.midX, y: previewPane.frame.midY)
            layoutActionBar()
        }
        let landscape = safe.width >= Self.landscapeBreakpoint && safe.width > safe.height * 1.2
        if safe.width >= Self.wideBreakpoint || landscape {
            let left = (safe.width * 0.56).rounded()
            previewPane.frame = CGRect(x: safe.minX, y: safe.minY, width: left, height: safe.height)
            controls.frame = CGRect(
                x: safe.minX + left, y: safe.minY, width: safe.width - left, height: safe.height)
            return
        }
        let ceiling = max(180, (safe.height * 0.42).rounded())
        var height = ceiling
        if let canvasHeight = selection.format.canvasHeight {
            let wanted =
                (safe.width - 2 * Self.inset) * CGFloat(canvasHeight / selection.format.canvasWidth)
                + 2 * Self.inset
            height = min(ceiling, wanted.rounded(.up))
        }
        previewPane.frame = CGRect(x: safe.minX, y: safe.minY, width: safe.width, height: height)
        controls.frame = CGRect(
            x: safe.minX, y: safe.minY + height, width: safe.width,
            height: safe.height - height)
    }

    /// Save and Copy stay where the thumb is whatever the controls above them are doing: the bar
    /// takes its height from its buttons, so a larger type size grows it instead of cutting it.
    private func layoutActionBar() {
        let pane = controls.frame
        let width = pane.width - 2 * Self.inset
        guard width > 0, actionBar.superview === view else { return }
        let fitted = actionBar.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        let height = max(ShareFlowView.minimumHit, fitted.height.rounded(.up))
        let barHeight = height + 2 * Theme.Spacing.s
        actionRule.frame = CGRect(x: pane.minX, y: pane.maxY - barHeight, width: pane.width, height: 1 / max(1, traitCollection.displayScale))
        actionBar.frame = CGRect(
            x: pane.minX + Self.inset, y: pane.maxY - barHeight + Theme.Spacing.s, width: width,
            height: height)
        controls.frame = CGRect(x: pane.minX, y: pane.minY, width: pane.width, height: pane.height - barHeight)
    }

    private func layoutPreview() {
        previewScroll.frame = previewPane.bounds
        let box = previewBox()
        guard let image = preview.image, image.size.width > 0, image.size.height > 0,
            box.width > 0, box.height > 0
        else { return }
        let aspect = image.size.height / image.size.width
        let scrolls = selection.format == .long
        let width = scrolls ? box.width : min(box.width, box.height / aspect)
        let height = width * aspect
        let x = Self.inset + (box.width - width) / 2
        let y = Self.inset
        preview.frame = CGRect(x: x, y: y, width: width.rounded(), height: height.rounded())
        previewScroll.contentSize = CGSize(
            width: previewScroll.bounds.width,
            height: scrolls ? height + 2 * Self.inset : previewScroll.bounds.height)
        previewScroll.alwaysBounceVertical = scrolls
    }

    private func exportScale(for card: AnalyticsShare.Card) -> CGFloat {
        AnalyticsCardRenderer.exportScale(for: card, displayScale: traitCollection.displayScale)
    }

    /// The file's bytes, drawn off the main thread and kept for as long as the choice stays the
    /// same, so Save, Copy and Share after one another draw once.
    private func exportedPNG() async -> (data: Data, filename: String)? {
        let card = package.card(selection, dark: isDark)
        let scale = exportScale(for: card)
        let key = ExportKey(selection: selection, dark: isDark, scale: scale)
        if let exported, exported.key == key { return (exported.data, exported.filename) }
        let share = package
        let filename = package.filename
        let data = await Task.detached(priority: .userInitiated) {
            AnalyticsCardRenderer.image(share.card(key.selection, dark: key.dark), scale: key.scale)
                .pngData()
        }.value
        guard let data else { return nil }
        exported = (key, data, filename)
        return (data, filename)
    }

    private func whileExporting(_ work: @escaping (Data, String) async -> Void) {
        guard !isExporting else { return }
        isExporting = true
        setActions(enabled: false)
        Task { [weak self] in
            let rendered = await self?.exportedPNG()
            guard let self else { return }
            self.isExporting = false
            self.setActions(enabled: true)
            guard let rendered else {
                AppLogger.ui.error("could not draw the analytics share")
                Theme.Haptics.error()
                return
            }
            await work(rendered.data, rendered.filename)
        }
    }

    private func setActions(enabled: Bool) {
        navigationItem.rightBarButtonItem?.isEnabled = enabled
        for button in actionButtons { button.isEnabled = enabled }
    }

    private func shareTapped() {
        whileExporting { [weak self] data, filename in
            guard let self else { return }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("shared-analytics", isDirectory: true)
                .appendingPathComponent(filename)
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                AppLogger.ui.error("could not stage analytics share: \(error)")
                Theme.Haptics.error()
                return
            }
            let sheet = UIActivityViewController(
                activityItems: [url, self.caption], applicationActivities: nil)
            sheet.popoverPresentationController?.barButtonItem = self.navigationItem.rightBarButtonItem
            Theme.Haptics.success()
            self.present(sheet, animated: true)
        }
    }

    private func saveToPhotos() {
        whileExporting { [weak self] data, filename in
            guard let self, let image = UIImage(data: data) else { return }
            let payload = ImagePayload(image: image, data: data, filename: filename)
            switch await ImageExport.saveToPhotos(payload) {
            case .saved:
                Theme.Haptics.success()
                self.toast(Localized.text("Saved to Photos"))
            case .denied:
                Theme.Haptics.warning()
                self.presentPhotoAccessAlert()
            case .failed:
                Theme.Haptics.error()
                self.toast(Localized.text("Couldn't save to Photos"))
            }
        }
    }

    private func copyImage() {
        whileExporting { [weak self] data, filename in
            guard let self, let image = UIImage(data: data) else { return }
            ImageExport.copy(ImagePayload(image: image, data: data, filename: filename))
            Theme.Haptics.success()
            self.toast(Localized.text("Image copied"))
        }
    }

    private func copyCaption() {
        UIPasteboard.general.string = caption
        Theme.Haptics.success()
        toast(Localized.text("Caption copied"))
    }

    private func presentPhotoAccessAlert() {
        let alert = UIAlertController(
            title: Localized.text("Photos access is off"),
            message: Localized.text("Tailscode needs permission to add pictures to your photo library."),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: Localized.text("Not Now"), style: .cancel))
        alert.addAction(
            UIAlertAction(title: Localized.text("Open Settings"), style: .default) { _ in
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            })
        present(alert, animated: true)
    }

    private func toast(_ message: String) {
        ToastView(message: message).flash(in: view, above: view.safeAreaLayoutGuide.bottomAnchor)
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}
