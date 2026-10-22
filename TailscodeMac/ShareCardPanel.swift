import AppKit
import TailscodeCore

/// The picture as it will leave, before it leaves. Sharing a picture nobody has seen is a guess, so
/// every road out of the analytics window — the share picker, the clipboard, a file — goes through
/// this sheet: the format (a post X shows whole, a square, a portrait, the full-length column), a
/// chip for every module the account can fill and the reason beside every one it cannot, the look,
/// and the picture itself, redrawn a moment after anything changes. The choice is remembered per
/// device; nothing in the window behind changes, because the share dresses the picture only.
@MainActor
final class ShareCardPanel {
    private static var active: [ShareCardPanel] = []
    static let redrawDelay: Duration = .milliseconds(150)

    private let analytics: UsageAnalytics
    private let package: AnalyticsShare
    private let defaults: UserDefaults
    let content = ShareSheetContent()
    private let toolbar = SheetToolbarView()
    private let presenter: SheetPresenter
    private var generation = 0
    private var redraw: Task<Void, Never>?
    private var isDirty = false
    private var outgoing: Task<Data?, Never>?
    private var refusal: String?

    private(set) var selection: ShareSelection
    private(set) var drawn: AnalyticsCardRenderer.Poster?

    static func present(
        _ analytics: UsageAnalytics, on host: NSWindow, selection: ShareSelection? = nil
    ) {
        let panel = ShareCardPanel(analytics: analytics, selection: selection)
        active.append(panel)
        panel.presenter.onClosed = { [weak panel] in
            guard let panel else { return }
            panel.redraw?.cancel()
            active.removeAll { $0 === panel }
        }
        panel.presenter.show(in: host, ready: {
            _ = host.makeFirstResponder(panel.content.focusTarget)
        })
        Task { await panel.settle() }
    }

    init(
        analytics: UsageAnalytics, selection: ShareSelection? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.analytics = analytics
        self.defaults = defaults
        package = AnalyticsShare(analytics)
        self.selection = selection ?? ShareSelectionStore.load(defaults: defaults)
        let sheet = SheetView(
            content: content, toolbar: toolbar, dialogName: Localized.text("Share card"),
            closeLabel: Localized.text("Done"))
        presenter = SheetPresenter(sheet: sheet, stack: .shared)
        let title = NSTextField(labelWithString: Localized.text("Share card"))
        title.font = MacTheme.Ramp.font(.panelTitle)
        title.textColor = MacTheme.Color.label
        toolbar.title = title
        let done = RowKit.ActionButton(title: Localized.text("Done")) { [weak self] in
            self?.close()
        }
        done.keyEquivalent = "\u{1B}"
        toolbar.trailing = [done]
        wire()
        refreshControls()
    }

    var fit: ShareFit { selection.fit(analytics) }

    var caption: String { package.caption(selection) }

    var altText: String { package.altText(selection) }

    var note: String? { refusal ?? fit.note }

    func close() {
        presenter.dismiss()
    }

    private func wire() {
        content.onFormat = { [weak self] in self?.choose($0) }
        content.onModule = { [weak self] in self?.press($0) }
        content.onStyle = { [weak self] in self?.pick($0) }
        content.onCopyCaption = { [weak self] in self?.copyCaption() }
        content.onCopyImage = { [weak self] in self?.copyCard() }
        content.onSave = { [weak self] in self?.saveCard() }
        content.onShare = { [weak self] in self?.shareCard() }
        content.onAppearanceChange = { [weak self] in self?.scheduleRedraw() }
    }

    func choose(_ format: ShareFormat) {
        guard format != selection.format else { return }
        selection.format = format
        selection.style = CardStyleSelection.current(for: format, defaults: defaults)
        refusal = nil
        remember()
        refreshControls()
        scheduleRedraw()
    }

    func press(_ module: ShareModule) {
        let outcome = selection.toggle(module, in: analytics)
        remember()
        if case .refused(let reason) = outcome {
            refusal = reason
            refreshControls()
            return
        }
        refusal = nil
        refreshControls()
        scheduleRedraw()
    }

    func pick(_ style: CardStyle) {
        guard style.id != selection.style.id else { return }
        selection.style = style
        defaults.set(style.id, forKey: CardStyleSelection.storageKey)
        scheduleRedraw()
    }

    private func remember() {
        ShareSelectionStore.save(selection, defaults: defaults)
    }

    private func refreshControls() {
        content.apply(selection: selection, fit: fit, note: note)
    }

    /// A change redraws a moment later, so dragging through the looks or switching three chips in
    /// a row costs one picture and not three.
    private func scheduleRedraw() {
        generation += 1
        isDirty = true
        let mine = generation
        redraw?.cancel()
        redraw = Task { [weak self] in
            try? await Task.sleep(for: Self.redrawDelay)
            guard !Task.isCancelled, let self, mine == self.generation else { return }
            await self.render(generation: mine)
        }
    }

    /// Draws the picture for what is chosen now and waits until it is on the sheet. The raster is
    /// made off the main thread; only handing the finished picture to the view happens here.
    func settle() async {
        if isDirty || drawn == nil {
            redraw?.cancel()
            await render(generation: generation)
        }
        _ = await outgoing?.value
    }

    private func render(generation mine: Int) async {
        isDirty = false
        let share = package
        let choice = selection
        let dark = content.isDark
        let density = content.previewScale(canvasWidth: choice.format.canvasWidth)
        let preview = await Task.detached(priority: .userInitiated) {
            AnalyticsCardRenderer.render(share, selection: choice, scale: density, dark: dark)
        }.value
        guard mine == generation, let preview else { return }
        drawn = preview
        content.show(preview: preview.nsImage, description: package.altText(choice))
        outgoing = Task.detached(priority: .userInitiated) {
            AnalyticsCardRenderer.png(share, selection: choice, scale: 2, dark: dark)
        }
    }

    /// Hands the finished picture to `use`: the full-density render of what the sheet shows now,
    /// begun with the preview so a press usually finds it done, and made first when a change is
    /// still waiting for its redraw, so what leaves is what was chosen.
    private func withCard(_ use: @escaping @MainActor (Data) -> Void) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await settle()
            guard let data = await outgoing?.value else { return }
            use(data)
        }
    }

    private func copyCaption() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(caption, forType: .string)
    }

    private func copyCard() {
        withCard { [package] data in
            guard let image = NSImage(data: data) else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([image])
            pasteboard.setString(package.plainText, forType: .string)
        }
    }

    private func saveCard() {
        withCard { [weak self] data in
            guard let self, let host = presenter.sheet.host else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = package.filename
            panel.allowedContentTypes = [.png]
            panel.beginSheetModal(for: host) { response in
                guard response == .OK, let url = panel.url else { return }
                do {
                    try data.write(to: url, options: .atomic)
                } catch {
                    NSAlert(error: error).beginSheetModal(for: host)
                }
            }
        }
    }

    private func shareCard() {
        withCard { [weak self] data in
            guard let self else { return }
            var items: [Any] = [caption]
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("shared-analytics", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(package.filename, isDirectory: false)
            if (try? data.write(to: url, options: .atomic)) != nil {
                items.insert(url, at: 0)
            } else if let image = NSImage(data: data) {
                items.insert(image, at: 0)
            }
            let anchor = content.shareAnchor
            NSSharingServicePicker(items: items).show(
                relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        }
    }
}
