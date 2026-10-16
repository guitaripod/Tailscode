import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// The checklist for one capability on one machine, in a window of its own that is transient for
/// the main window like the other dialogs.
///
/// Every road in leads here — the call control on a server without voice, the server screen's
/// capability row, the harness — and what it shows is Core's `SetupChecklist` read from the
/// process's `SetupDesk`. The desk polls only while this window is open: the lifetime that holds
/// the watch ends on `close-request`, so a closed checklist asks its machine for nothing. When
/// everything is proven the primary button finishes it, which closes the window and runs what the
/// caller wanted next (starting the call).
///
/// A window presented from a local variable is a window whose buttons do nothing, so this one holds
/// itself for exactly as long as it is open.
final class SetupWindow: @unchecked Sendable {
    nonisolated(unsafe) private static var shared: SetupWindow?

    static var current: SetupWindow? { shared }

    /// Opens the checklist, or raises the one already open for this target. A second target replaces
    /// the first, because two checklists open at once is two machines being asked about for nobody.
    /// `fixture` puts a fixed snapshot on screen with no machine behind it, for the harness.
    static func present(
        target: SetupTarget, parent: UnsafeMutablePointer<GtkWidget>?, fixture: SetupSnapshot? = nil,
        reportLines: @escaping @Sendable () -> [String] = { [] }, onFinish: (@Sendable () -> Void)? = nil
    ) {
        if let open = shared {
            if open.target == target, open.fixture == nil, fixture == nil {
                open.onFinish = onFinish ?? open.onFinish
                gtk_window_present(ptr(open.window))
                return
            }
            open.close()
        }
        shared = SetupWindow(
            target: target, parent: parent, fixture: fixture, reportLines: reportLines, onFinish: onFinish)
    }

    static func dismiss() { shared?.close() }

    private let target: SetupTarget
    private let fixture: SetupSnapshot?
    private let window: UnsafeMutablePointer<GtkWidget>
    private let view: SetupChecklistView
    private let lifetime = PaneLifetime()
    private var onFinish: (@Sendable () -> Void)?
    private var closed = false
    private(set) var checklist: SetupChecklist?

    private init(
        target: SetupTarget, parent: UnsafeMutablePointer<GtkWidget>?, fixture: SetupSnapshot?,
        reportLines: @escaping @Sendable () -> [String], onFinish: (@Sendable () -> Void)?
    ) {
        self.target = target
        self.fixture = fixture
        self.onFinish = onFinish
        view = SetupChecklistView(reportLines: reportLines)
        let name = SetupReading.name(of: target.capability)
        let made = Dialogs.windowWithActions(title: name, parent: parent, width: 600)
        window = made.window
        gtk_window_set_modal(ptr(window), 0)
        gtk_window_set_default_size(ptr(window), 600, 820)
        gtk_box_append(ptr(made.content), view.widget)
        gtk_box_append(ptr(made.actions), view.footer)

        view.onPrimary = { [weak self] action in Gtk.onMain { [weak self] in self?.pressed(action) } }
        view.onFix = { [weak self] fix in Gtk.onMain { [weak self] in self?.start(fix) } }
        view.onCancel = { [weak self] in Gtk.onMain { [weak self] in self?.cancel() } }
        Gtk.observe(UnsafeMutableRawPointer(window), "close-request") { [weak self] in self?.dismissed() }
        Gtk.onKey(window) { [weak self] keyval, _ in
            guard keyval == Keymap.escape else { return false }
            Gtk.onMain { [weak self] in self?.close() }
            return true
        }

        if let fixture {
            show(fixture)
        } else {
            SetupRunner.shared.desk.follow(target, lifetime: lifetime) { [weak self] snapshot in
                Gtk.onMain { [weak self] in self?.show(snapshot) }
            }
        }
        gtk_window_present(ptr(window))
        gtk_window_set_focus(ptr(window), nil)
    }

    private func show(_ snapshot: SetupSnapshot) {
        guard !closed else { return }
        let next = SetupChecklist(snapshot: snapshot)
        checklist = next
        view.apply(next)
    }

    private func pressed(_ action: SetupAction) {
        switch action {
        case .setUp:
            guard fixture == nil else { return }
            let target = target
            Task { await SetupRunner.shared.desk.runAll(target) }
        case .copy:
            break
        case .finish:
            finish()
        case .askPassword:
            askPassword()
        }
    }

    private func start(_ fix: SetupRowFix) {
        guard fixture == nil else { return }
        let target = target
        Task { await SetupRunner.shared.desk.start(fix: fix.id, for: target) }
    }

    private func cancel() {
        guard fixture == nil else { return }
        let target = target
        Task { await SetupRunner.shared.desk.cancel(target) }
    }

    private func askPassword() {
        let target = target
        Dialogs.prompt(
            title: Localized.text("Voice gateway password"), body: VoiceReach.wantsPassword.line, placeholder: "",
            confirmLabel: Localized.text("Save"), secret: true, parent: window
        ) { password in
            guard !password.isEmpty else { return }
            Task { await SetupRunner.shared.desk.remember(password: password, for: target) }
        }
    }

    private func finish() {
        let next = onFinish
        close()
        next?()
    }

    func close() {
        guard !closed else { return }
        gtk_window_close(ptr(window))
    }

    private func dismissed() {
        guard !closed else { return }
        closed = true
        lifetime.cancelAll()
        view.tearDown()
        if Self.shared === self { Self.shared = nil }
    }

    var reading: String {
        "setup target=\(target.capability)@\(target.host) fixture=\(fixture != nil) \(view.report)"
    }

    var viewForHarness: SetupChecklistView { view }
}
