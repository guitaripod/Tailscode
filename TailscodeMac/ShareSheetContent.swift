import AppKit
import TailscodeCore

/// One module's switch: a chip with the module's symbol and word, lit with the accent while the
/// picture holds it. A module the account cannot fill, or one more than the format holds, is dimmed
/// and cannot be pressed, and its tooltip and help say why in Core's words.
@MainActor
final class ShareModuleChip: SymbolChip {
    let module: ShareModule

    init(module: ShareModule) {
        self.module = module
        super.init(kind: .control)
        symbol = module.symbolName
        text = module.title
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(module.title)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ state: ShareFit.ChipState) {
        switch state {
        case .on:
            accented = true
            isEnabled = true
            alphaValue = 1
            toolTip = module.title
            setAccessibilityHelp(nil)
            setAccessibilityValue(1)
        case .off:
            accented = false
            isEnabled = true
            alphaValue = 1
            toolTip = module.title
            setAccessibilityHelp(nil)
            setAccessibilityValue(0)
        case .blocked(let reason):
            accented = false
            isEnabled = false
            alphaValue = 0.45
            toolTip = reason
            setAccessibilityHelp(reason)
            setAccessibilityValue(0)
        }
    }
}

/// What the share sheet holds, placed by frame: the format, a wrapping row of module chips, the
/// sentence about what a full format left out, the look, the picture itself at the size that fits
/// what is left, and the ways out along the foot. It only draws what its owner tells it and says
/// what was pressed; every choice, every word and every redraw is `ShareCardPanel`'s.
@MainActor
final class ShareSheetContent: NSView {
    var onFormat: ((ShareFormat) -> Void)?
    var onModule: ((ShareModule) -> Void)?
    var onStyle: ((CardStyle) -> Void)?
    var onCopyCaption: (() -> Void)?
    var onCopyImage: (() -> Void)?
    var onSave: (() -> Void)?
    var onShare: (() -> Void)?
    var onAppearanceChange: (() -> Void)?

    private let formatLabel = ShareSheetContent.dimLabel(Localized.text("Format"))
    private let formats = NSSegmentedControl()
    private let modulesLabel = ShareSheetContent.dimLabel(Localized.text("Modules"))
    private var chips: [ShareModuleChip] = []
    private let note = NSTextField(wrappingLabelWithString: "")
    private let styleLabel = ShareSheetContent.dimLabel(Localized.text("Card style"))
    private let styles = NSPopUpButton()
    private let preview = NSImageView()
    private let caption: RowKit.ActionButton
    private let copy: RowKit.ActionButton
    private let save: RowKit.ActionButton
    private let share: RowKit.ActionButton
    private var captionTitle: String
    private var copyTitle: String
    private var flashes: [ObjectIdentifier: Task<Void, Never>] = [:]
    private(set) var previewSize: NSSize?

    private static let margin: CGFloat = 20
    private static let gap: CGFloat = 10
    private static let chipGap: CGFloat = 6
    private static let previewGap: CGFloat = 14

    private static func dimLabel(_ words: String) -> NSTextField {
        let label = NSTextField(labelWithString: words)
        label.font = MacTheme.Ramp.font(.panelLabel)
        label.textColor = MacTheme.Color.secondaryLabel
        label.setAccessibilityElement(false)
        return label
    }

    init() {
        captionTitle = Localized.text("Copy caption")
        copyTitle = Localized.text("Copy image")
        caption = RowKit.ActionButton(title: captionTitle) {}
        copy = RowKit.ActionButton(title: copyTitle) {}
        save = RowKit.ActionButton(title: Localized.text("Save as…")) {}
        share = RowKit.ActionButton(title: Localized.text("Share")) {}
        super.init(frame: .zero)
        setAccessibilityRole(.group)
        setAccessibilityLabel(Localized.text("Share card"))
        buildFormats()
        buildChips()
        buildStyles()
        buildPreview()
        buildActions()
        for view in [formatLabel, formats, modulesLabel] { addSubview(view) }
        chips.forEach { addSubview($0) }
        for view in [note, styleLabel, styles, preview, caption, copy, save, share] { addSubview(view) }
        note.isHidden = true
        note.font = MacTheme.Ramp.font(.panelLabel)
        note.textColor = MacTheme.Color.secondaryLabel
        note.isSelectable = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    var focusTarget: NSView { formats }

    var shareAnchor: NSView { share }

    var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func buildFormats() {
        formats.segmentCount = ShareFormat.allCases.count
        formats.trackingMode = .selectOne
        formats.segmentStyle = .automatic
        for (index, format) in ShareFormat.allCases.enumerated() {
            formats.setLabel(format.title, forSegment: index)
            formats.setImage(
                NSImage(systemSymbolName: format.symbolName, accessibilityDescription: nil),
                forSegment: index)
            formats.setImageScaling(.scaleProportionallyDown, forSegment: index)
            formats.setToolTip(format.tagline, forSegment: index)
            formats.setWidth(0, forSegment: index)
        }
        formats.target = self
        formats.action = #selector(formatPressed)
        formats.setAccessibilityLabel(Localized.text("Format"))
    }

    private func buildChips() {
        chips = ShareModule.selectable.map { module in
            let chip = ShareModuleChip(module: module)
            chip.onTap = { [weak self] in self?.onModule?(module) }
            return chip
        }
    }

    private func buildStyles() {
        for candidate in CardStyle.all {
            let item = NSMenuItem(title: candidate.name, action: nil, keyEquivalent: "")
            item.image = AnalyticsCardRenderer.swatch(candidate)
            item.toolTip = candidate.tagline
            item.representedObject = candidate.id
            styles.menu?.addItem(item)
        }
        styles.target = self
        styles.action = #selector(stylePressed)
        styles.setAccessibilityLabel(Localized.text("Card style"))
        styles.toolTip = Localized.text("Card style")
    }

    private func buildPreview() {
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.imageAlignment = .alignCenter
        preview.wantsLayer = true
        preview.layer?.cornerRadius = MacTheme.Radius.card
        preview.layer?.cornerCurve = .continuous
        preview.layer?.masksToBounds = true
        preview.setAccessibilityLabel(Localized.text("Card preview"))
    }

    private func buildActions() {
        caption.setAction { [weak self] in
            guard let self else { return }
            self.onCopyCaption?()
            self.confirm(self.caption, restoring: self.captionTitle)
        }
        copy.setAction { [weak self] in
            guard let self else { return }
            self.onCopyImage?()
            self.confirm(self.copy, restoring: self.copyTitle)
        }
        save.setAction { [weak self] in self?.onSave?() }
        share.setAction { [weak self] in self?.onShare?() }
        share.keyEquivalent = "\r"
        caption.setAccessibilityLabel(captionTitle)
        copy.setAccessibilityLabel(copyTitle)
    }

    /// The press said what it did by changing its own word for a moment: a copy has no window of
    /// its own to show it in, and the word goes back so the button is never left saying "Copied"
    /// about something that was copied a minute ago.
    private func confirm(_ button: RowKit.ActionButton, restoring title: String) {
        let key = ObjectIdentifier(button)
        flashes[key]?.cancel()
        button.title = Localized.text("Copied")
        flashes[key] = Task { @MainActor [weak button] in
            try? await Task.sleep(for: .milliseconds(1400))
            guard !Task.isCancelled else { return }
            button?.title = title
        }
    }

    @objc private func formatPressed() {
        let index = formats.selectedSegment
        guard ShareFormat.allCases.indices.contains(index) else { return }
        onFormat?(ShareFormat.allCases[index])
    }

    @objc private func stylePressed() {
        guard let id = styles.selectedItem?.representedObject as? String else { return }
        onStyle?(CardStyle.named(id))
    }

    func apply(selection: ShareSelection, fit: ShareFit, note text: String?) {
        if let index = ShareFormat.allCases.firstIndex(of: selection.format) {
            formats.selectedSegment = index
        }
        for chip in chips { chip.show(fit.state(of: chip.module)) }
        if let index = CardStyle.all.firstIndex(where: { $0.id == selection.style.id }) {
            styles.selectItem(at: index)
        }
        let words = text ?? ""
        note.stringValue = words
        note.isHidden = words.isEmpty
        needsLayout = true
    }

    func show(preview image: NSImage, description: String) {
        preview.image = image
        previewSize = image.size
        preview.setAccessibilityLabel(description)
        preview.setAccessibilityTitle(Localized.text("Card preview"))
        needsLayout = true
    }

    func isChipEnabled(_ module: ShareModule) -> Bool {
        chips.first { $0.module == module }?.isEnabled ?? false
    }

    func isChipOn(_ module: ShareModule) -> Bool {
        chips.first { $0.module == module }?.accented ?? false
    }

    func chipHelp(_ module: ShareModule) -> String? {
        chips.first { $0.module == module }?.toolTip
    }

    var chipFrames: [CGRect] { chips.map(\.frame) }

    var previewFrame: CGRect { preview.frame }

    /// Pixels per point the preview is drawn at: as many as the room it will fill has on this
    /// screen, between the card's own size and the density a copy leaves at.
    func previewScale(canvasWidth: Double) -> CGFloat {
        let room = max(0, bounds.width - Self.margin * 2)
        let density = window?.backingScaleFactor ?? 1
        return min(2, max(1, room * density / CGFloat(canvasWidth)))
    }

    var previewDescription: String? { preview.accessibilityLabel() }

    var buttonTitles: [String] { [caption, copy, save, share].map(\.title) }

    private func size(of view: NSView) -> NSSize {
        let intrinsic = view.intrinsicContentSize
        let natural = intrinsic.width >= 0 && intrinsic.height >= 0 ? intrinsic : view.fittingSize
        return NSSize(width: ceil(natural.width), height: ceil(natural.height))
    }

    override func layout() {
        super.layout()
        let margin = Self.margin
        let room = max(0, bounds.width - margin * 2)
        var y = margin

        let formatsSize = size(of: formats)
        let labelSize = size(of: formatLabel)
        formatLabel.frame = NSRect(
            x: margin, y: y + (formatsSize.height - labelSize.height) / 2, width: labelSize.width,
            height: labelSize.height)
        let formatsX = margin + labelSize.width + Self.gap
        formats.frame = NSRect(
            x: formatsX, y: y, width: min(formatsSize.width, max(0, bounds.width - margin - formatsX)),
            height: formatsSize.height)
        y += formatsSize.height + Self.gap + 4

        let modulesSize = size(of: modulesLabel)
        modulesLabel.frame = NSRect(x: margin, y: y, width: modulesSize.width, height: modulesSize.height)
        y += modulesSize.height + 6
        y = placeChips(from: y, room: room)

        if !note.isHidden {
            let height = ceil(note.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: room, height: 10_000)).height ?? 16)
            note.frame = NSRect(x: margin, y: y + 6, width: room, height: height)
            y = note.frame.maxY
        }
        y += Self.gap

        let styleLabelSize = size(of: styleLabel)
        let stylesSize = size(of: styles)
        styleLabel.frame = NSRect(
            x: margin, y: y + (stylesSize.height - styleLabelSize.height) / 2,
            width: styleLabelSize.width, height: styleLabelSize.height)
        styles.frame = NSRect(
            x: margin + styleLabelSize.width + Self.gap, y: y, width: stylesSize.width,
            height: stylesSize.height)
        y += stylesSize.height + Self.previewGap

        let buttonHeight = max(size(of: share).height, 24)
        let footY = max(y, bounds.height - margin - buttonHeight)
        placeActions(y: footY, height: buttonHeight, room: room)

        let available = NSRect(
            x: margin, y: y, width: room, height: max(0, footY - Self.previewGap - y))
        preview.frame = fitted(available)
    }

    /// Chips run left to right and wrap at the sheet's width, so a narrow window makes more rows
    /// and never a chip the sheet cuts off.
    private func placeChips(from top: CGFloat, room: CGFloat) -> CGFloat {
        var x = Self.margin
        var y = top
        var rowHeight: CGFloat = 0
        for chip in chips {
            let size = size(of: chip)
            if x > Self.margin, x + size.width > Self.margin + room {
                x = Self.margin
                y += rowHeight + Self.chipGap
                rowHeight = 0
            }
            chip.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
            x += size.width + Self.chipGap
            rowHeight = max(rowHeight, size.height)
        }
        return y + rowHeight
    }

    private func placeActions(y: CGFloat, height: CGFloat, room: CGFloat) {
        var x = Self.margin
        for button in [caption, copy, save] {
            let size = size(of: button)
            button.frame = NSRect(x: x, y: y, width: size.width, height: height)
            x += size.width + Self.gap
        }
        let shareSize = size(of: share)
        share.frame = NSRect(
            x: Self.margin + room - shareSize.width, y: y, width: shareSize.width, height: height)
    }

    /// The picture at its own proportions in the room that is left, under the controls. Nothing here knows the
    /// format: a 16:9 post and a 4:5 portrait are only two shapes to fit.
    private func fitted(_ room: NSRect) -> NSRect {
        guard let size = previewSize, size.width > 0, size.height > 0, room.width > 0, room.height > 0
        else { return NSRect(x: room.minX, y: room.minY, width: room.width, height: 0) }
        let factor = min(room.width / size.width, room.height / size.height)
        let width = (size.width * factor).rounded(.down)
        let height = (size.height * factor).rounded(.down)
        return NSRect(
            x: room.minX + (room.width - width) / 2, y: room.minY, width: width, height: height)
    }
}
