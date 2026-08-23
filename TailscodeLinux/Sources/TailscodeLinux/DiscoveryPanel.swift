import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// Setting a machine up should be a scan, not a form.
///
/// Everything this app talks to is already on the tailnet, and on Linux the tailnet can be read
/// for free — `tailscale status --json` lists every peer, so nothing has to be typed and no API
/// credential has to be minted before the app can go and look. The shared `TailnetScanner` asks
/// each online peer on both agent ports; anything that answers becomes a row that adds itself.
///
/// The wait is drawn rather than spun. `TailnetRadar` is the arithmetic and `RadarView` paints it,
/// which is the same dial the renderer's own sweep turns. A machine keeps the place its own name
/// gives it, so a second scan puts it back where the reader last saw it.
final class DiscoveryPanel: @unchecked Sendable {
    private let onAdd: @Sendable (TailnetScanner.Suggestion) -> Void
    private let onChanged: @Sendable () -> Void

    let group: UnsafeMutablePointer<GtkWidget>
    private let radar = RadarView()
    private let statusRow: UnsafeMutablePointer<GtkWidget>
    private let statusActions: UnsafeMutablePointer<GtkWidget>
    private var resultRows: [UnsafeMutablePointer<GtkWidget>] = []

    private var found: [TailnetScanner.Suggestion] = []
    private var configured: Set<String> = []
    private var scanID = 0
    private var checked = 0
    private var total = 0
    private var peerCount = 0
    private var startedAt = 0.0

    init(
        onAdd: @escaping @Sendable (TailnetScanner.Suggestion) -> Void,
        onChanged: @escaping @Sendable () -> Void
    ) {
        self.onAdd = onAdd
        self.onChanged = onChanged

        group = adw_preferences_group_new()!
        adw_preferences_group_set_title(ptr(group), Localized.text("Find my machines"))
        adw_preferences_group_set_description(
            ptr(group),
            Localized.text("Every machine on your tailnet, asked on both agent ports."))

        adw_preferences_group_add(ptr(group), ptr(radar.preferencesRow()))

        let row = adw_action_row_new()!
        adw_preferences_row_set_use_markup(ptr(row), 0)
        adw_action_row_set_subtitle_lines(ptr(row), 0)
        statusRow = row
        let actions = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        gtk_widget_set_valign(actions, GTK_ALIGN_CENTER)
        statusActions = actions
        adw_action_row_add_suffix(ptr(row), actions)
        adw_preferences_group_add(ptr(group), ptr(row))

        rest()
    }

    /// Which servers are already saved, so a machine the app already has offers a fact rather than
    /// a second copy of itself.
    func setConfigured(_ profiles: [ConnectionProfile]) {
        configured = Set(profiles.map { Self.key(host: $0.baseURL.host ?? "", port: $0.baseURL.port ?? 0) })
        renderResults()
    }

    func scan() {
        guard !radar.scanning else { return }
        scanID += 1
        let id = scanID
        radar.scanning = true
        radar.blips = []
        found = []
        checked = 0
        total = 0
        peerCount = 0
        startedAt = RadarView.now
        renderResults()
        setStatus(Localized.text("Reading your tailnet…"), detail: "", actions: [])
        radar.startClock()

        Task { [weak self] in
            let status = TailnetStatusLinux.read()
            let devices = status.scannableDevices()
            Gtk.onMain { [weak self] in
                guard let self, self.scanID == id else { return }
                self.peerCount = devices.count
                guard !devices.isEmpty else {
                    self.finish(
                        id: id,
                        note: status.address == nil
                            ? Localized.text(
                                "Tailscale isn't running here, so there is no tailnet to look at.")
                            : Localized.text(
                                "No other machine on your tailnet is awake right now."))
                    return
                }
                self.setStatus(
                    Self.count(devices.count, one: "Asking 1 machine…", many: "Asking %@ machines…"),
                    detail: "", actions: [])
            }
            guard !devices.isEmpty else { return }

            let scanner = TailnetScanner()
            let report: @Sendable (Int, Int) -> Void = { [weak self] done, count in
                Gtk.onMain { [weak self] in
                    guard let self, self.scanID == id else { return }
                    self.checked = done
                    self.total = count
                    self.setStatus(
                        Self.count(
                            self.peerCount, one: "Asking 1 machine…", many: "Asking %@ machines…"),
                        detail: Localized.text(
                            "Asked %@ of %@ ports.", "\(done)", "\(count)"),
                        actions: [])
                }
            }
            let sighted: @Sendable (TailnetScanner.Suggestion) -> Void = { [weak self] suggestion in
                Gtk.onMain { [weak self] in
                    guard let self, self.scanID == id else { return }
                    self.light(suggestion)
                }
            }
            let complete = await Self.within(30) {
                await scanner.scan(devices: devices, onProgress: report, onFound: sighted)
            }
            Gtk.onMain { [weak self] in
                guard let self, self.scanID == id else { return }
                guard let complete else {
                    self.finish(
                        id: id,
                        stalled: Localized.text(
                            "Some machines never answered — a peer that is asleep holds the port open and says nothing."
                        ))
                    return
                }
                self.found = complete
                self.radar.blips = complete.map { self.blip(for: $0, bornAt: self.startedAt) }
                self.finish(id: id, note: nil)
            }
        }
    }

    /// A machine takes its place on the dial the moment it answers, rather than when the whole
    /// sweep is over — the picture is the progress, so it has to move while the scan runs.
    private func light(_ suggestion: TailnetScanner.Suggestion) {
        let made = blip(for: suggestion, bornAt: RadarView.now)
        guard !radar.blips.contains(where: { $0.key == made.key }) else { return }
        radar.blips.append(made)
        found.append(suggestion)
        renderResults()
    }

    /// A scan that never comes back is a spinner with extra steps. A peer that has gone to sleep
    /// holds its port open and answers nothing, so the probe against it neither succeeds nor fails
    /// — the whole sweep is given a deadline and reports what it did find.
    private static func within<T: Sendable>(
        _ seconds: Int, _ work: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func blip(for suggestion: TailnetScanner.Suggestion, bornAt: Double) -> RadarBlip {
        RadarBlip(
            key: suggestion.dedupeKey, tone: suggestion.requiresAuth ? .locked : .ready,
            bornAt: bornAt)
    }

    private func finish(id: Int, note: String? = nil, stalled: String? = nil) {
        guard scanID == id else { return }
        radar.scanning = false
        renderResults()
        let again = Self.button(Localized.text("Scan again")) { [weak self] in self?.scan() }
        if let note {
            setStatus(Localized.text("Nothing to add"), detail: note, actions: [again])
        } else if let stalled, !found.isEmpty {
            setStatus(
                Self.count(found.count, one: "1 found", many: "%@ found"),
                detail: stalled, actions: [again])
        } else if let stalled {
            setStatus(
                Localized.text("Nothing answered in time"), detail: stalled, actions: [again])
        } else if found.isEmpty {
            setStatus(
                Localized.text("No agents answered"),
                detail: Self.count(
                    peerCount,
                    one:
                        "Asked 1 machine on both ports. Run the install command on the machine you code on, then scan again.",
                    many:
                        "Asked %@ machines on both ports. Run the install command on the machine you code on, then scan again."
                ),
                actions: [
                    Self.button(Localized.text("Copy the install command")) { [weak self] in
                        Gtk.copyToClipboard(BridgeInstall.installCommand)
                        self?.onChanged()
                    },
                    again,
                ])
        } else {
            setStatus(
                Self.count(found.count, one: "1 found", many: "%@ found"),
                detail: Self.count(
                    peerCount, one: "Across 1 machine on your tailnet.",
                    many: "Across %@ machines on your tailnet."),
                actions: [again])
        }
        radar.draw()
    }

    private func rest() {
        setStatus(
            Localized.text("Nothing scanned yet"),
            detail: Localized.text("Ask every machine on your tailnet which agent it runs."),
            actions: [Self.button(Localized.text("Scan my tailnet")) { [weak self] in self?.scan() }])
        radar.draw()
    }

    private func renderResults() {
        for row in resultRows { adw_preferences_group_remove(ptr(group), ptr(row)) }
        resultRows = []
        for suggestion in found {
            let row = adw_action_row_new()!
            adw_preferences_row_set_use_markup(ptr(row), 0)
            adw_preferences_row_set_title(ptr(row), suggestion.recommendedProfileName)
            adw_action_row_set_subtitle_lines(ptr(row), 0)
            adw_action_row_set_subtitle(ptr(row), Self.detail(suggestion))
            let glyph = Gtk.label(
                suggestion.requiresAuth ? "🔒" : "●",
                css: suggestion.requiresAuth ? "glyph-needs" : "glyph-done", selectable: false)
            gtk_widget_set_valign(glyph, GTK_ALIGN_CENTER)
            adw_action_row_add_prefix(ptr(row), glyph)

            let key = Self.key(
                host: suggestion.baseURL.host ?? "", port: suggestion.baseURL.port ?? 0)
            if configured.contains(key) {
                let mark = Gtk.label(Localized.text("Already added"), css: "dim", selectable: false)
                gtk_widget_set_valign(mark, GTK_ALIGN_CENTER)
                adw_action_row_add_suffix(ptr(row), mark)
            } else {
                let found = suggestion
                adw_action_row_add_suffix(
                    ptr(row),
                    Self.button(Localized.text("Add"), css: ["suggested-action"]) { [weak self] in
                        self?.onAdd(found)
                    })
            }
            adw_preferences_group_add(ptr(group), ptr(row))
            resultRows.append(row)
        }
    }

    private static func detail(_ suggestion: TailnetScanner.Suggestion) -> String {
        var parts = [ServerLabel.agent(suggestion.backend)]
        if let host = suggestion.baseURL.host, let port = suggestion.baseURL.port {
            parts.append("\(host):\(port)")
        }
        if let version = suggestion.version, !version.isEmpty { parts.append(version) }
        if suggestion.requiresAuth { parts.append(Localized.text("wants a password")) }
        return parts.joined(separator: " · ")
    }

    /// One is a machine, two are machines. A count spliced into a sentence has to carry its own
    /// grammar or the app reads like a log line.
    private static func count(_ value: Int, one: String, many: String) -> String {
        value == 1 ? Localized.text(one) : Localized.text(many, "\(value)")
    }

    private static func key(host: String, port: Int) -> String { "\(host.lowercased()):\(port)" }

    private func setStatus(
        _ title: String, detail: String, actions: [UnsafeMutablePointer<GtkWidget>]
    ) {
        adw_preferences_row_set_title(ptr(statusRow), title)
        adw_action_row_set_subtitle(ptr(statusRow), detail)
        Gtk.removeChildren(of: statusActions)
        for action in actions { gtk_box_append(ptr(statusActions), action) }
        gtk_widget_set_visible(statusActions, actions.isEmpty ? 0 : 1)
    }

    private static func button(
        _ title: String, css: [String] = ["flat"], onClick: @escaping @Sendable () -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let button = Gtk.button(title, css: css, onClick: onClick)
        gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
        return button
    }
}
