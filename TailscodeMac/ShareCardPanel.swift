import AppKit
import TailscodeCore

/// The card as it will leave, before it leaves. Sharing a picture nobody has seen is a guess, so
/// every road out of the analytics window — the share picker, the clipboard, a file — goes
/// through this sheet: the card drawn at the chosen look, a pop-up that redraws it the moment
/// another look is picked, and the three ways out beside it. The choice is remembered; nothing
/// in the window behind changes, because the look dresses the card only.
@MainActor
final class ShareCardPanel {
    private static var active: [ShareCardPanel] = []

    private let sheet: NSWindow
    private let share: AnalyticsShare
    private let preview = NSImageView()
    private let previewHeight: NSLayoutConstraint
    private let styles = NSPopUpButton()
    private var style = CardStyleSelection.current
    private var renderGeneration = 0
    /// The card at the look on screen and at full density, as the three ways out hand it over.
    /// Begun with the preview so a press usually finds it finished, and drawn under the same
    /// light as the preview, so what leaves is what was shown even if the Mac changed appearance
    /// while the sheet was up.
    private var outgoing: Task<Data?, Never>?
    private weak var shareAnchor: NSView?

    private static let previewWidth: CGFloat = 560

    static func present(_ analytics: UsageAnalytics, on host: NSWindow) {
        let panel = ShareCardPanel(analytics: analytics)
        active.append(panel)
        host.beginSheet(panel.sheet) { _ in
            active.removeAll { $0 === panel }
        }
        panel.render()
    }

    private init(analytics: UsageAnalytics) {
        share = AnalyticsShare(analytics)
        sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 640),
            styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        sheet.title = Localized.text("Share card")

        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.imageAlignment = .alignTop
        preview.wantsLayer = true
        preview.layer?.cornerRadius = MacTheme.Radius.card
        preview.layer?.masksToBounds = true
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.widthAnchor.constraint(equalToConstant: Self.previewWidth).isActive = true
        previewHeight = preview.heightAnchor.constraint(equalToConstant: 400)
        previewHeight.isActive = true
        preview.setAccessibilityLabel(Localized.text("Card preview"))

        let holder = NSStackView(views: [preview])
        holder.orientation = .vertical
        let scroll = MacDialogs.scrollColumn(holding: holder)
        scroll.heightAnchor.constraint(equalToConstant: 520).isActive = true

        for candidate in CardStyle.all {
            let item = NSMenuItem(title: candidate.name, action: nil, keyEquivalent: "")
            item.image = AnalyticsCardRenderer.swatch(candidate)
            item.toolTip = candidate.tagline
            item.representedObject = candidate.id
            styles.menu?.addItem(item)
            if candidate.id == style.id { styles.select(item) }
        }
        styles.target = self
        styles.action = #selector(styleChanged(_:))
        styles.setAccessibilityLabel(Localized.text("Card style"))

        let label = NSTextField(labelWithString: Localized.text("Card style"))
        label.font = MacTheme.Ramp.font(.panelLabel)
        label.textColor = MacTheme.Color.secondaryLabel
        let picker = NSStackView(views: [label, styles, RowKit.spacer()])
        picker.orientation = .horizontal
        picker.spacing = MacTheme.Spacing.s

        let copy = RowKit.ActionButton(title: Localized.text("Copy")) { [weak self] in
            self?.copyCard()
        }
        let save = RowKit.ActionButton(title: Localized.text("Save…")) { [weak self] in
            self?.saveCard()
        }
        let send = RowKit.ActionButton(title: Localized.text("Share")) { [weak self] in
            self?.shareCard()
        }
        send.keyEquivalent = "\r"
        shareAnchor = send
        let done = RowKit.ActionButton(title: Localized.text("Done")) { [weak self] in
            self?.close()
        }
        done.keyEquivalent = "\u{1B}"
        let footer = NSStackView(views: [done, RowKit.spacer(), copy, save, send])
        footer.orientation = .horizontal
        footer.spacing = MacTheme.Spacing.s

        let column = NSStackView(views: [picker, scroll, footer])
        column.orientation = .vertical
        column.spacing = MacTheme.Spacing.m
        column.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        column.widthAnchor.constraint(equalToConstant: 600).isActive = true
        sheet.contentView = column
    }

    @objc private func styleChanged(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String else { return }
        let picked = CardStyle.named(id)
        guard picked.id != style.id else { return }
        style = picked
        CardStyleSelection.set(picked)
        render()
    }

    /// The preview is drawn at the card's own logical size — every word, a quarter of the pixels
    /// the share will carry — so a look is judged in a beat rather than after a Retina render.
    private func render() {
        renderGeneration += 1
        let generation = renderGeneration
        let share = share
        let style = style
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        outgoing = Task.detached(priority: .userInitiated) {
            AnalyticsCardRenderer.png(share, dark: dark, style: style)?.data
        }
        Task.detached(priority: .userInitiated) {
            let rendered = AnalyticsCardRenderer.png(share, scale: 1, dark: dark, style: style)
            let image = rendered.flatMap { NSImage(data: $0.data) }
            await MainActor.run { [weak self] in
                guard let self, generation == self.renderGeneration, let image else { return }
                self.preview.image = image
                self.previewHeight.constant =
                    (Self.previewWidth * image.size.height / image.size.width).rounded()
            }
        }
    }

    /// Hands the finished card to `use` once it is drawn, off the main thread, so a press never
    /// stalls the sheet on a Retina render.
    private func withCard(_ use: @escaping @MainActor (Data) -> Void) {
        guard let outgoing else { return }
        Task { @MainActor in
            guard let data = await outgoing.value else { return }
            use(data)
        }
    }

    private func copyCard() {
        withCard { [share] data in
            guard let image = NSImage(data: data) else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([image])
            pasteboard.setString(share.plainText, forType: .string)
        }
    }

    private func saveCard() {
        withCard { [weak self] data in
            guard let self else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = share.filename
            panel.allowedContentTypes = [.png]
            panel.beginSheetModal(for: sheet) { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                do {
                    try data.write(to: url, options: .atomic)
                } catch {
                    guard let sheet = self?.sheet else { return }
                    NSAlert(error: error).beginSheetModal(for: sheet)
                }
            }
        }
    }

    private func shareCard() {
        withCard { [weak self] data in
            guard let self, let source = shareAnchor ?? sheet.contentView else { return }
            var items: [Any] = [share.plainText]
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("shared-analytics", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(share.filename, isDirectory: false)
            if (try? data.write(to: url, options: .atomic)) != nil {
                items.insert(url, at: 0)
            } else if let image = NSImage(data: data) {
                items.insert(image, at: 0)
            }
            let picker = NSSharingServicePicker(items: items)
            picker.show(relativeTo: source.bounds, of: source, preferredEdge: .minY)
        }
    }

    private func close() {
        sheet.sheetParent?.endSheet(sheet)
    }
}
