import AVKit
import AppKit
import CodingAgentKit
import TailscodeCore
import UniformTypeIdentifiers

/// The words the viewer's sheet owns.
enum MediaViewerWords {
    static var dialogName: String { Localized.text("Viewer, dialog") }
    static var closeLabel: String { Localized.text("Close viewer") }
    static var previousTip: String { Localized.text("Previous picture (←)") }
    static var nextTip: String { Localized.text("Next picture (→)") }
    static var copyTip: String { Localized.text("Copy the picture (⌘C)") }
    static var saveTip: String { Localized.text("Save to Downloads (⌘S)") }
    static var fitTip: String { Localized.text("Show the whole picture (0)") }
    static var actualTip: String { Localized.text("One image pixel per screen pixel (1)") }
}

/// What the viewer's sheet holds: a content on the lights-down canvas and the toolbar row that goes
/// with it. A surface is told when it has been put in front of the person, when its sheet starts to
/// leave and when it is gone, and answers the keys the viewer's table gives it.
@MainActor
class ViewerSurface: NSView {
    let toolbar = SheetToolbarView()
    var onClose: (() -> Void)?
    var onSay: ((String) -> Void)?
    private(set) var layoutPasses = 0
    private let notice = ViewerNotice()

    override var isFlipped: Bool { true }

    /// Where the keyboard goes when the viewer comes up.
    var focusTarget: NSView { self }

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        layoutPasses += 1
        let size = notice.intrinsicContentSize
        let width = min(size.width, max(0, bounds.width - 48))
        notice.frame = NSRect(
            x: (bounds.width - width) / 2, y: bounds.height - 24 - size.height, width: width, height: size.height)
    }

    func arrive() {}

    func leave() {}

    func finish() {}

    func handle(_ key: ViewerKey) -> Bool { false }

    func say(_ text: String) {
        if let onSay { onSay(text) } else { notify(text) }
    }

    func notify(_ text: String) {
        if notice.superview == nil { addSubview(notice) }
        notice.say(text)
        needsLayout = true
        NSAccessibility.post(
            element: self, notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    func makeDoneButton() -> NSButton {
        let done = RowKit.ActionButton(title: ImageGenSurface.dismissTitle) { [weak self] in self?.onClose?() }
        done.setAccessibilityLabel(MediaViewerWords.closeLabel)
        return done
    }

    func makeSymbolButton(_ symbol: String, label: String, tip: String, action: @escaping () -> Void) -> NSButton {
        let button = RowKit.ActionButton(title: "", action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [MacTheme.Color.label]))
        button.imagePosition = .imageOnly
        button.bezelStyle = .texturedRounded
        button.showsBorderOnlyWhileMouseInside = true
        button.setAccessibilityLabel(label)
        button.toolTip = tip
        return button
    }
}

/// A capsule at the foot of the viewer that says what a press did — "Saved …", "Copied" — for a moment.
/// The viewer covers the places an answer would otherwise appear, so it carries its own.
@MainActor
private final class ViewerNotice: NSView {
    private let label = StudioTheme.label(.panelLabel, color: MacTheme.Color.label)
    private var generation = 0

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        isHidden = true
        label.lineBreakMode = .byTruncatingMiddle
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var intrinsicContentSize: NSSize {
        let text = label.intrinsicContentSize
        return NSSize(width: ceil(text.width) + 28, height: ceil(text.height) + 14)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        label.frame = bounds.insetBy(dx: 14, dy: 7)
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
    }

    override var wantsUpdateLayer: Bool { true }

    func say(_ text: String) {
        label.stringValue = text
        invalidateIntrinsicContentSize()
        isHidden = false
        alphaValue = 1
        generation += 1
        let mine = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.6))
            guard let self, self.generation == mine else { return }
            self.isHidden = true
        }
    }
}

/// A scroll view that answers a double-click, which fits a picture or takes it to true pixels.
@MainActor
private final class ViewerScrollView: NSScrollView {
    var onDoubleClick: (() -> Void)?

    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() }
        super.mouseUp(with: event)
    }
}

/// A clip view that centres a document smaller than the pane, which a magnified-out picture is.
@MainActor
private final class ViewerClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposed)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width { rect.origin.x = document.frame.midX - rect.width / 2 }
        if rect.height > document.frame.height { rect.origin.y = document.frame.midY - rect.height / 2 }
        return rect
    }
}

/// The name and the line under it — place among the pictures and size — in the middle of the toolbar.
@MainActor
private final class ViewerTitle: NSView {
    let name = StudioTheme.label(.panelLabel, color: MacTheme.Color.label)
    let detail = StudioTheme.label(.panelFootnote, color: MacTheme.Color.secondaryLabel)

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        name.font = MacTheme.Ramp.font(.rowTitleStrong)
        name.lineBreakMode = .byTruncatingMiddle
        name.alignment = .center
        detail.lineBreakMode = .byTruncatingTail
        detail.alignment = .center
        addSubview(name)
        addSubview(detail)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var detailHeight: CGFloat { detail.isHidden ? 0 : StudioTheme.height(of: .panelFootnote) }

    override var intrinsicContentSize: NSSize {
        let detailWidth = detail.isHidden ? 0 : detail.intrinsicContentSize.width
        return NSSize(
            width: ceil(max(name.intrinsicContentSize.width, detailWidth)) + 4,
            height: StudioTheme.height(of: .rowTitleStrong) + detailHeight)
    }

    override var fittingSize: NSSize { intrinsicContentSize }

    override func layout() {
        super.layout()
        let nameHeight = StudioTheme.height(of: .rowTitleStrong)
        name.frame = NSRect(x: 0, y: 0, width: bounds.width, height: nameHeight)
        detail.frame = NSRect(x: 0, y: nameHeight, width: bounds.width, height: detailHeight)
    }
}

/// A gallery over every picture in the conversation: paged with ‹ › or the arrow keys, magnifiable
/// between fit and true 1:1 screen pixels with a double-click, `1`, `0` and `+ −`, and a save that hands
/// over the exact bytes the server sent under their sniffed extension. Pages whose bytes are still being
/// fetched paint the moment they land.
@MainActor
final class PictureGalleryView: ViewerSurface {
    private(set) var items: [ImageViewer.Item]
    private(set) var pager: ViewerPager
    private(set) var zoom = ViewerZoom()

    private var fetch: (FileReference, String) -> Void
    private let scrollView = ViewerScrollView()
    private let imageView = NSImageView()
    private let title = ViewerTitle()
    private let zoomButton = RowKit.ActionButton(title: "") {}
    private var previousButton: NSButton?
    private var nextButton: NSButton?
    private var paneWhenFitted: CGSize = .zero
    private var magnifyObserver: NSObjectProtocol?

    init(items: [ImageViewer.Item], startKey: String, fetch: @escaping (FileReference, String) -> Void) {
        self.items = items
        self.pager = ViewerPager(count: items.count, index: items.firstIndex { $0.key == startKey } ?? 0)
        self.fetch = fetch
        super.init(frame: .zero)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.setAccessibilityRole(.image)
        scrollView.contentView = ViewerClipView()
        scrollView.documentView = imageView
        scrollView.allowsMagnification = true
        scrollView.minMagnification = ViewerZoom.limits.lowerBound
        scrollView.maxMagnification = ViewerZoom.limits.upperBound
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.onDoubleClick = { [weak self] in self?.toggleZoom() }
        addSubview(scrollView)
        magnifyObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveMagnifyNotification, object: scrollView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pinched() }
        }
        buildToolbar()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var focusTarget: NSView { self }

    var currentItem: ImageViewer.Item { items[pager.index] }

    var magnification: CGFloat { scrollView.magnification }

    var zoomTitle: String { zoomButton.title }

    var canPage: Bool { items.count > 1 }

    private func buildToolbar() {
        var leading: [NSView] = []
        let previous = makeSymbolButton(
            "chevron.left", label: Localized.text("Previous picture"), tip: MediaViewerWords.previousTip
        ) { [weak self] in self?.step(-1) }
        let next = makeSymbolButton(
            "chevron.right", label: Localized.text("Next picture"), tip: MediaViewerWords.nextTip
        ) { [weak self] in self?.step(1) }
        previousButton = previous
        nextButton = next
        leading = [previous, next]
        zoomButton.setAction { [weak self] in self?.toggleZoom() }
        zoomButton.bezelStyle = .rounded
        zoomButton.font = MacTheme.Ramp.font(.control)
        let copy = makeSymbolButton(
            "doc.on.doc", label: Localized.text("Copy"), tip: MediaViewerWords.copyTip
        ) { [weak self] in self?.copyPicture() }
        let save = makeSymbolButton(
            "arrow.down.to.line", label: Localized.text("Save to Downloads"), tip: MediaViewerWords.saveTip
        ) { [weak self] in self?.savePicture() }
        toolbar.leading = leading
        toolbar.title = title
        toolbar.trailing = [zoomButton, copy, save, makeDoneButton()]
        updatePagingControls()
    }

    private func updatePagingControls() {
        previousButton?.isHidden = !canPage
        nextButton?.isHidden = !canPage
        toolbar.needsLayout = true
    }

    /// Points the gallery somewhere else while it stands: another set of pictures, or the same set at
    /// another one. The sheet does not move; the page does.
    func retarget(items next: [ImageViewer.Item], startKey: String, fetch: @escaping (FileReference, String) -> Void) {
        items = next
        pager = ViewerPager(count: next.count, index: next.firstIndex { $0.key == startKey } ?? 0)
        self.fetch = fetch
        zoom.fit()
        updatePagingControls()
    }

    override func arrive() {
        render()
    }

    override func finish() {
        if let magnifyObserver { NotificationCenter.default.removeObserver(magnifyObserver) }
        magnifyObserver = nil
    }

    /// A picture's bytes landed: the page that was waiting for them paints.
    func stored(_ key: String) {
        guard key == currentItem.key else { return }
        render()
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        guard zoom.mode != .custom, scrollView.contentSize != paneWhenFitted else { return }
        applyMagnification()
    }

    override func handle(_ key: ViewerKey) -> Bool {
        switch key {
        case .previous: step(-1)
        case .next, .advance: step(1)
        case .first: go { $0.first() }
        case .last: go { $0.last() }
        case .zoomIn: zoomStep(1)
        case .zoomOut: zoomStep(-1)
        case .fit:
            zoom.fit()
            applyMagnification()
        case .actual:
            zoom.actual()
            applyMagnification()
        case .toggleZoom: toggleZoom()
        case .copy: copyPicture()
        case .save: savePicture()
        case .close: return false
        }
        return true
    }

    func step(_ delta: Int) {
        go { $0.step(delta) }
    }

    private func go(_ move: (inout ViewerPager) -> Void) {
        move(&pager)
        zoom.fit()
        render()
    }

    func toggleZoom() {
        zoom.toggle()
        applyMagnification()
    }

    private func zoomStep(_ direction: Int) {
        guard imageView.image != nil else { return }
        let scale = zoom.stepped(from: scrollView.magnification, in: direction)
        scrollView.setMagnification(scale, centeredAt: visibleCentre)
        zoomButton.title = zoomButtonTitle
    }

    private func pinched() {
        zoom.mode = .custom
        zoomButton.title = zoomButtonTitle
    }

    private var visibleCentre: NSPoint {
        let visible = scrollView.documentVisibleRect
        return NSPoint(x: visible.midX, y: visible.midY)
    }

    private var zoomButtonTitle: String {
        zoom.mode == .actual ? Localized.text("Fit") : Localized.text("1:1")
    }

    /// The line under the name: where this picture is among the others, and how big it is, or that its
    /// bytes are still on their way.
    private func setDetail(_ last: String) {
        title.detail.stringValue = [pager.counter, last].compactMap { $0 }.joined(separator: "  ·  ")
        title.invalidateIntrinsicContentSize()
        toolbar.needsLayout = true
    }

    func render() {
        let item = currentItem
        title.name.stringValue = item.name
        imageView.setAccessibilityLabel(item.name)
        guard let entry = ImageStore.shared.entry(forKey: item.key) else {
            setDetail(Localized.text("Loading…"))
            imageView.image = nil
            applyMagnification()
            fetch(item.reference, item.key)
            return
        }
        setDetail("\(entry.pixelWidth)×\(entry.pixelHeight)")
        imageView.image = entry.image
        imageView.setFrameSize(NSSize(width: CGFloat(entry.pixelWidth), height: CGFloat(entry.pixelHeight)))
        applyMagnification()
    }

    /// The zoom the mode asks for, in the pane as it is now. The document view is sized in image pixels,
    /// so one image pixel per screen pixel is a magnification of one over the backing scale.
    private func applyMagnification() {
        zoomButton.title = zoomButtonTitle
        zoomButton.toolTip = zoom.mode == .actual ? MediaViewerWords.fitTip : MediaViewerWords.actualTip
        toolbar.needsLayout = true
        guard imageView.image != nil, imageView.frame.width > 0, imageView.frame.height > 0 else { return }
        paneWhenFitted = scrollView.contentSize
        let backing = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        guard
            let scale = zoom.scale(
                pane: scrollView.contentSize, image: imageView.frame.size, backingScale: backing,
                margin: MacTheme.Spacing.l)
        else { return }
        scrollView.setMagnification(scale, centeredAt: NSPoint(x: imageView.frame.midX, y: imageView.frame.midY))
    }

    /// The original bytes on the pasteboard, under the type they actually are — never the bitmap a
    /// bubble downsampled to display.
    func copyPicture() {
        guard let entry = ImageStore.shared.entry(forKey: currentItem.key) else {
            say(Localized.text("Still loading — try again in a moment."))
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if !entry.data.isEmpty, let ext = ImageBytes.sniffedExtension(entry.data),
            let type = UTType(filenameExtension: ext)
        {
            pasteboard.setData(entry.data, forType: NSPasteboard.PasteboardType(type.identifier))
        } else {
            pasteboard.writeObjects([entry.image])
        }
        say(ImageGenWords.copiedNotice)
    }

    /// The person's own Downloads folder, asked of the file manager rather than built out of a home
    /// path: inside a container the home directory *is* the container, so a hand-built path writes
    /// the picture where nobody will ever look for it under a toast naming a folder it is not in.
    func savePicture() {
        let item = currentItem
        guard let entry = ImageStore.shared.entry(forKey: item.key) else {
            say(Localized.text("Still loading — try again in a moment."))
            return
        }
        let filename = ImageBytes.exportFilename(item.name, data: entry.data)
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            say(Localized.text("This Mac has no Downloads folder to write to."))
            return
        }
        let target = downloads.appendingPathComponent(filename)
        let wrote = (try? entry.data.write(to: target)) != nil
        say(wrote ? Localized.text("Saved %@", target.path) : Localized.text("Could not write %@", target.path))
    }
}

/// A clip at full size on the same canvas, with the system's own controls: the Studio's stage keeps its
/// room and a second look at a clip is not a reason to give up the first. Space plays and pauses.
@MainActor
final class ClipPlayerView: ViewerSurface {
    let url: URL
    private let player: AVPlayer
    private let playerView = AVPlayerView()
    private let title = ViewerTitle()
    private let save: (@escaping @MainActor (String) -> Void) -> Void
    private let share: (NSView) -> Void

    init(
        url: URL, title name: String, save: @escaping (@escaping @MainActor (String) -> Void) -> Void,
        share: @escaping (NSView) -> Void
    ) {
        self.url = url
        self.save = save
        self.share = share
        player = AVPlayer(url: url)
        super.init(frame: .zero)
        playerView.controlsStyle = .floating
        playerView.videoGravity = .resizeAspect
        playerView.player = player
        addSubview(playerView)
        title.name.stringValue = name
        title.detail.isHidden = true
        let saveButton = makeSymbolButton(
            "arrow.down.to.line", label: Localized.text("Save"), tip: Localized.text("Save")
        ) { [weak self] in self?.saveClip() }
        let shareButton = makeSymbolButton(
            "square.and.arrow.up", label: Localized.text("Share"), tip: Localized.text("Share")
        ) { [weak self] in
            guard let self else { return }
            self.share(self)
        }
        toolbar.title = title
        toolbar.trailing = [saveButton, shareButton, makeDoneButton()]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var focusTarget: NSView { playerView }

    var isPlaying: Bool { player.timeControlStatus != .paused }

    var hasControls: Bool { playerView.controlsStyle == .floating && playerView.player === player }

    var videoBounds: CGRect { playerView.videoBounds }

    var isReadyForDisplay: Bool { playerView.isReadyForDisplay }

    override func layout() {
        super.layout()
        playerView.frame = bounds
    }

    override func arrive() {
        player.play()
    }

    override func leave() {
        player.pause()
    }

    override func finish() {
        player.pause()
        playerView.player = nil
    }

    func togglePlayback() {
        if player.timeControlStatus == .paused { player.play() } else { player.pause() }
    }

    override func handle(_ key: ViewerKey) -> Bool {
        switch key {
        case .advance:
            togglePlayback()
            return true
        case .save:
            saveClip()
            return true
        default:
            return false
        }
    }

    private func saveClip() {
        save { [weak self] line in self?.say(line) }
    }
}
