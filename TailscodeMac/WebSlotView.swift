import AppKit
import TailscodeCore
import WebKit

/// A page living inside the split tree. `WKWebView` is an NSView, so the page is tiled by the same
/// split view as the transcripts around it — the dividers resize it, zoom hides its siblings, and
/// closing the pane hands the space back. An empty slot asks for an address in its own body; a
/// loaded one shows nothing but the page, because a browser pane that keeps chrome is just a small
/// browser window.
@MainActor
final class WebSlotView: NSView {
    private(set) var slot: WebSlot
    private let webView: WKWebView
    private let promptStack = FillingStack()
    private let field = NSTextField()
    private let headingLabel = NSTextField(labelWithString: Localized.text("Browse"))
    private let reasonLabel = NSTextField(wrappingLabelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private var observations: [NSKeyValueObservation] = []

    private static let promptWidth: CGFloat = 460

    var onChange: (() -> Void)?

    init(target: WebTarget?) {
        slot = WebSlot(target: target)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: .zero)
        build()
        if let target {
            point(at: target)
        } else {
            render()
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func build() {
        wantsLayer = true
        applyBackground()

        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.navigationDelegate = self
        webView.isHidden = true
        addSubview(webView)

        headingLabel.font = MacTheme.Ramp.font(.cardTitle)
        headingLabel.alignment = .center
        headingLabel.maximumNumberOfLines = 1
        headingLabel.lineBreakMode = .byTruncatingTail
        reasonLabel.font = MacTheme.Ramp.font(.panelFootnote)
        reasonLabel.textColor = MacTheme.Color.secondaryLabel
        reasonLabel.alignment = .center
        reasonLabel.isSelectable = false
        reasonLabel.maximumNumberOfLines = 0
        reasonLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hintLabel.font = MacTheme.Ramp.font(.panelFootnote)
        hintLabel.textColor = MacTheme.Color.secondaryLabel
        hintLabel.alignment = .center
        hintLabel.maximumNumberOfLines = 1
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hintLabel.stringValue = slot.hint

        field.placeholderString = slot.prompt
        field.font = MacTheme.Ramp.font(.panelLabel)
        field.target = self
        field.action = #selector(submit)
        field.translatesAutoresizingMaskIntoConstraints = false

        promptStack.spacing = MacTheme.Spacing.m
        promptStack.translatesAutoresizingMaskIntoConstraints = false
        promptStack.setViews([headingLabel, field, reasonLabel, hintLabel], in: .center)
        addSubview(promptStack)

        let preferredWidth = promptStack.widthAnchor.constraint(
            equalToConstant: Self.promptWidth)
        preferredWidth.priority = .defaultLow

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            promptStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            promptStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            promptStack.widthAnchor.constraint(lessThanOrEqualToConstant: Self.promptWidth),
            promptStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor, constant: MacTheme.Spacing.l),
            promptStack.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -MacTheme.Spacing.l),
            preferredWidth,
        ])
        observe()
    }

    /// The ground the question sits on, asked again whenever the window's face changes: a colour
    /// put in a layer keeps the light it was born under, and this pane is the app's own canvas
    /// rather than a page's.
    private func applyBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = MacTheme.Color.canvas.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBackground()
    }

    /// The page tells the slot what it is: its own title, where it ended up, and how far along it
    /// is. Nothing here polls — a page that redirects renames the pane the moment it lands.
    private func observe() {
        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.arrived() }
            },
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.arrived() }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in
                    self?.slot.progress(view.estimatedProgress)
                    self?.render()
                }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in self?.slot.canGoBack = view.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in self?.slot.canGoForward = view.canGoForward }
            },
        ]
    }

    /// What the page has become, unless the pane has already been told the load failed: WebKit
    /// hands the previous address back when a navigation dies, and taking that as an arrival would
    /// put the pane on the blank page the failure is there to explain.
    private func arrived() {
        guard !isFailed else { return }
        slot.arrived(url: webView.url?.absoluteString, title: webView.title)
        render()
    }

    private var isFailed: Bool {
        if case .failed = slot.phase { return true }
        return false
    }

    var target: WebTarget? { slot.target }
    var isAsking: Bool { slot.isAsking }
    var currentAddress: String? { slot.currentURL }

    /// One line for the headless selftest: the phase, then what the slot is showing.
    var summary: String {
        let phase: String
        switch slot.phase {
        case .asking: phase = "asking"
        case .loading: phase = "loading"
        case .showing: phase = "showing"
        case .failed: phase = "failed"
        }
        return "\(phase) \(slot.currentURL ?? slot.target?.url ?? "-") [\(slot.title)]"
    }

    func focusPrompt() {
        window?.makeFirstResponder(field)
    }

    @objc private func submit() {
        guard let target = WebTarget.classify(field.stringValue) else { return }
        point(at: target)
    }

    func point(at target: WebTarget) {
        slot.point(at: target)
        guard let url = URL(string: target.url) else {
            slot.failed(Localized.text("That page would not open"))
            render()
            return
        }
        webView.load(URLRequest(url: url))
        render()
    }

    func ask() {
        slot.ask()
        field.stringValue = slot.draft
        render()
        focusPrompt()
        field.currentEditor()?.selectAll(nil)
    }

    func handle(_ command: WebCommand) {
        switch command {
        case .address:
            ask()
        case .back:
            webView.goBack()
        case .forward:
            webView.goForward()
        case .reload:
            guard isFailed, let target = slot.target else {
                webView.reload()
                return
            }
            point(at: target)
        case .stop:
            webView.stopLoading()
        case .zoomIn, .zoomOut, .zoomReset:
            slot.zoom = WebCommand.zoom(slot.zoom, command)
            webView.pageZoom = slot.zoom
            render()
        }
    }

    func shutdown() {
        observations.forEach { $0.invalidate() }
        observations = []
        webView.navigationDelegate = nil
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }

    private func render() {
        let asking = slot.isAsking
        var failed = false
        if case .failed(let reason) = slot.phase {
            failed = true
            reasonLabel.stringValue = reason
        }
        reasonLabel.isHidden = !failed
        webView.isHidden = asking || failed
        promptStack.isHidden = !(asking || failed)
        hintLabel.stringValue = slot.hint
        onChange?()
    }
}

extension WebSlotView: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        pageFailed(error)
    }

    func webView(
        _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error
    ) {
        pageFailed(error)
    }

    /// A page that cannot be reached is a state the pane has to arrive at too. Progress alone never
    /// says so — a dead host simply stops short of 1 — so the slot would sit at "Loading 30%" over
    /// WebKit's blank page until somebody retyped the address. A cancelled load is not a failure:
    /// it is the navigation that replaced it, or this pane shutting down.
    private func pageFailed(_ error: any Error) {
        let failure = error as NSError
        guard failure.domain != NSURLErrorDomain || failure.code != NSURLErrorCancelled else {
            return
        }
        slot.failed(failure.localizedDescription)
        render()
    }
}
