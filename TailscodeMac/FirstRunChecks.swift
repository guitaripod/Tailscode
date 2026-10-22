import AppKit
import TailscodeCore

/// First run on the Mac, drawn: every state `FirstRunFixtures` can put on screen goes through the
/// real window and the real welcome, and the words, the one primary, Return and Escape are read
/// back from what was drawn. What the plan says is Core's to prove; this proves the Mac draws it.
@MainActor
enum FirstRunChecks {
    static func run() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("first run: \(label)") }
            checks += 1
        }
        let first = try drawn("machine-asking")
        let adding = try drawn("machine-asking+add")
        defer {
            first.closeFixture()
            adding.closeFixture()
        }
        try everyStateDraws(first, adding, expect)
        try states(first, expect)
        try addition(adding, expect)
        try welcome(expect)
        try pane(expect)
        return checks
    }

    private typealias Expect = (Bool, String) throws -> Void

    private static func drawn(_ name: String) throws -> FirstRunWindow {
        guard let window = FirstRunWindow.presentFixture(named: name, ordersFront: false) else {
            throw SelfTestFailure("first run: no state \(name)")
        }
        return window
    }

    private static func everyStateDraws(
        _ first: FirstRunWindow, _ adding: FirstRunWindow, _ expect: Expect
    ) throws {
        for name in FirstRunFixtures.names + FirstRunFixtures.names.map({ $0 + "+add" }) {
            let window = name.hasSuffix("+add") ? adding : first
            try expect(window.redraw(fixtureNamed: name), "\(name) is a state of its window")
            try expect(!window.drawnTexts.isEmpty, "\(name) draws words")
            try expect(window.escapeButtons.count == 1, "\(name) has one Escape: \(window.escapeButtons)")
            if let primary = window.returnButton {
                try expect(!primary.title.isEmpty, "\(name) names its primary action")
            }
        }
    }

    private static func states(_ window: FirstRunWindow, _ expect: Expect) throws {
        func show(_ name: String) throws {
            try expect(window.redraw(fixtureNamed: name), "\(name) is a state")
        }
        try show("machine-asking")
        var texts = window.drawnTexts
        try expect(texts.contains("Tailscale on this Mac"), "the Tailscale row is first run's")
        try expect(texts.contains("Open or paste a link"), "the link way leads")
        try expect(texts.contains("I don't have a machine set up yet"), "the install way is offered")
        try expect(texts.contains("Try the demo"), "first run keeps the demo one press away")
        try expect(window.returnButton == nil, "nothing is primary before there is something to connect")
        try expect(window.escapeButtons == ["Later"], "Escape is Later")
        try expect(window.windowTitle == "Welcome", "first run is a welcome")

        try show("tailscale-down")
        texts = window.drawnTexts
        try expect(texts.contains(TailscaleReading.daemonDown.title), "Tailscale not running is the pill")
        try expect(
            texts.filter { $0 == TailscaleReading.daemonDown.detail }.count == 1,
            "and its own remedy is drawn once")

        try show("link-offered")
        texts = window.drawnTexts
        try expect(texts.contains("Use the link you copied"), "a copied link is offered")
        try expect(
            texts.contains("Studio · studio.tail1234.ts.net:4098"), "by the machine's name and place")
        try expect(!texts.contains { $0.contains("key") && $0.contains("tailscode://") }, "never as the link")

        try show("link-pasted")
        texts = window.drawnTexts
        try expect(window.returnButton?.title == "Connect to Studio", "Return connects to the machine")
        try expect(window.returnButton?.isEnabled == true, "and can be pressed")
        try expect(texts.contains("Add Studio"), "the link says what it would add")
        try expect(!texts.contains("Use the link you copied"), "a link in play is not offered again")

        try show("probing")
        try expect(window.drawnTexts.contains("Looking for Studio…"), "a probe says whom it is asking")
        try expect(window.returnButton?.isEnabled == false, "and Connect waits for the answer")

        try show("failed:refused")
        texts = window.drawnTexts
        try expect(
            texts.contains { $0.hasPrefix("Nothing is listening on ") && $0.contains("studio") },
            "a failure names the machine: \(texts)")
        try expect(texts.contains("Try again"), "and offers the one tap that fixes it")

        try show("failed:off-tailnet")
        try expect(window.drawnTexts.contains("Open Tailscale"), "a machine off the tailnet opens Tailscale")

        try show("signed-out")
        texts = window.drawnTexts
        try expect(window.returnButton?.title == "Sign in to Claude", "a signed-out Claude is the primary")
        try expect(window.escapeButtons == ["Later"], "and Escape is Later, not a closed window")
        try expect(!texts.contains("Not now"), "Not now is not offered beside Later")
        try expect(texts.filter { $0 == "Sign in to Claude" }.count == 1, "the sign-in is pressed in one place")

        try show("connected")
        try expect(window.returnButton == nil, "a connected machine has nothing left to press")
    }

    private static func addition(_ window: FirstRunWindow, _ expect: Expect) throws {
        try expect(window.redraw(fixtureNamed: "machine-asking+add"), "adding is a state")
        let texts = window.drawnTexts
        try expect(window.windowTitle == "Add a machine", "adding is named")
        try expect(!texts.contains("Try the demo"), "adding offers no demo")
        try expect(!texts.contains { $0.hasPrefix("Tailscale on this") }, "adding never claims Tailscale is missing")
        try expect(window.escapeButtons == ["Not now"], "and Escape is Not now")
    }

    private static func welcome(_ expect: Expect) throws {
        let view = EmptyWelcomeView()
        var answered: [EmptyWelcome.Intent] = []
        view.onAction = { answered.append($0) }
        func press(_ title: String) {
            func find(_ candidate: NSView) -> NSButton? {
                if let button = candidate as? NSButton, button.title == title { return button }
                return candidate.subviews.lazy.compactMap(find).first
            }
            find(view)?.performClick(nil)
        }

        let ready = EmptyWelcome.make(try welcomeState("machine-asking"))
        view.show(ready)
        try expect(
            view.buttonTitles == ["Set up a machine", "Paste a link", "Try the demo"],
            "the welcome offers a machine first, then a link, then the demo: \(view.buttonTitles)")
        press("Paste a link")
        press("Set up a machine")
        press("Try the demo")
        try expect(answered == [.pasteLink, .setUpMachine, .tryDemo], "each button answers its intent")

        view.show(EmptyWelcome.make(try welcomeState("tailscale-down")))
        let down = TailscaleReading.daemonDown
        try expect(
            view.buttonTitles.first == down.actionTitle, "Tailscale down leads with Tailscale's own remedy")
        try expect(view.buttonTitles.contains("Set up a machine"), "and still offers the machine")

        view.show(EmptyWelcome.make(try welcomeState("signed-out")))
        try expect(view.buttonTitles == ["Sign in to Claude"], "a signed-out Claude is the one thing offered")
    }

    private static func welcomeState(_ name: String) throws -> FirstRunState {
        guard let state = FirstRunFixtures.state(named: name, platform: .mac) else {
            throw SelfTestFailure("first run: no state \(name)")
        }
        return state
    }

    private static func pane(_ expect: Expect) throws {
        let pane = TranscriptViewController()
        _ = pane.view
        try expect(pane.shownWelcome == nil, "a pane starts without a welcome")
        pane.showWelcome(EmptyWelcome.make(try welcomeState("machine-asking"))) { _ in }
        try expect(pane.shownWelcome?.primary.title == "Set up a machine", "an empty pane draws the welcome")
        try expect(!pane.welcomeButtonTitles.isEmpty, "with its buttons")
        pane.clearWelcome()
        try expect(pane.shownWelcome == nil, "and it goes away when a server is saved")

        var chooser = PaneChooser(servers: [], entries: [])
        chooser.offersPreview = false
        pane.showChooser(chooser)
        pane.showWelcome(EmptyWelcome.make(try welcomeState("machine-asking"))) { _ in }
        try expect(pane.shownWelcome == nil, "a pane that is asking which server keeps its question")
        pane.shutdownPane()
    }
}
