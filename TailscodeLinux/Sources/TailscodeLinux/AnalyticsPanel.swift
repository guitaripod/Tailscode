import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// The month in numbers behind the usage panel's footer: every connected Claude server's
/// transcript ledger merged by Core's `UsageAnalytics` into one account — spend per day, the
/// week's rhythm and the day's clock, models, projects, tools, cache economics, records and
/// insights. Every word and every number comes from Core; this file only decides how tall a
/// bar is.
enum AnalyticsPanel {
    private static let meterTrack = 456
    private static let dayChartHeight = 90
    private static let dayBarWidth = 14
    private static let weekdayChartHeight = 46
    private static let weekdayBarWidth = 52
    private static let hourChartHeight = 34
    private static let hourBarWidth = 16

    /// The open panel's own widgets, so a span picked inside it can reload it. The window owns
    /// them for as long as it is up; every load takes its own reference for the trip through the
    /// task and drops it on the way out.
    private nonisolated(unsafe) static var openColumn: UInt = 0
    private nonisolated(unsafe) static var openShareSlot: UInt = 0
    private nonisolated(unsafe) static var openWindow: UInt = 0

    static func present(parent: UnsafeMutablePointer<GtkWidget>?) {
        let (window, content) = Dialogs.window(
            title: UsageWindow.current.surfaceTitle, parent: parent, width: 560)
        gtk_window_set_default_size(ptr(window), 560, 720)

        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 12)

        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_widget_set_vexpand(scroller, 1)
        gtk_scrolled_window_set_child(op(scroller), column)
        gtk_box_append(ptr(content), scroller)

        let windowBits = UInt(bitPattern: window)
        let actions = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_widget_set_halign(actions, GTK_ALIGN_END)
        Gtk.margins(actions, top: 4)

        let shareSlot = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_box_append(ptr(actions), shareSlot)

        let dismiss = Gtk.button(Localized.text("Close"), css: ["suggested-action"]) {
            guard let raw = UnsafeMutableRawPointer(bitPattern: windowBits) else { return }
            gtk_window_destroy(ptr(raw))
        }
        gtk_box_append(ptr(actions), dismiss)
        gtk_box_append(ptr(content), actions)
        Gtk.onKey(window) { keyval, _ in
            guard keyval == Keymap.escape else { return false }
            guard let raw = UnsafeMutableRawPointer(bitPattern: windowBits) else { return true }
            gtk_window_destroy(ptr(raw))
            return true
        }
        gtk_window_present(ptr(window))
        gtk_widget_grab_focus(dismiss)

        openColumn = UInt(bitPattern: column)
        openShareSlot = UInt(bitPattern: shareSlot)
        openWindow = UInt(bitPattern: window)
        load()
    }

    /// Reads the ledger for whatever span is chosen and redraws into the open panel. Called once
    /// when the panel opens and again whenever somebody picks a different span.
    private static func load() {
        guard let columnRaw = UnsafeMutableRawPointer(bitPattern: openColumn),
            let shareRaw = UnsafeMutableRawPointer(bitPattern: openShareSlot),
            let windowRaw = UnsafeMutableRawPointer(bitPattern: openWindow),
            gtk_widget_get_root(ptr(columnRaw)) != nil
        else { return }
        let column: UnsafeMutablePointer<GtkWidget> = ptr(columnRaw)
        let shareSlot: UnsafeMutablePointer<GtkWidget> = ptr(shareRaw)
        let window: UnsafeMutablePointer<GtkWidget> = ptr(windowRaw)
        Gtk.removeChildren(of: column)
        Gtk.removeChildren(of: shareSlot)
        gtk_box_append(ptr(column), notice(Localized.text("Reading the ledger…")))

        g_object_ref(UnsafeMutableRawPointer(column))
        g_object_ref(UnsafeMutableRawPointer(shareSlot))
        g_object_ref(UnsafeMutableRawPointer(window))
        let columnBits = UInt(bitPattern: column)
        let shareBits = UInt(bitPattern: shareSlot)
        let heldWindowBits = UInt(bitPattern: window)
        let span = UsageWindow.current
        Task.detached {
            let analytics = await gather(window: span)
            Gtk.onMain {
                defer {
                    if let raw = UnsafeMutableRawPointer(bitPattern: columnBits) {
                        g_object_unref(raw)
                    }
                    if let raw = UnsafeMutableRawPointer(bitPattern: shareBits) {
                        g_object_unref(raw)
                    }
                    if let raw = UnsafeMutableRawPointer(bitPattern: heldWindowBits) {
                        g_object_unref(raw)
                    }
                }
                guard let columnRaw = UnsafeMutableRawPointer(bitPattern: columnBits),
                    gtk_widget_get_root(ptr(columnRaw)) != nil
                else { return }
                render(analytics, into: ptr(columnRaw))
                guard let shareRaw = UnsafeMutableRawPointer(bitPattern: shareBits),
                    let windowRaw = UnsafeMutableRawPointer(bitPattern: heldWindowBits),
                    let analytics
                else { return }
                installShare(
                    analytics, into: ptr(shareRaw), window: ptr(windowRaw))
            }
        }
    }

    private static func installShare(
        _ analytics: UsageAnalytics,
        into slot: UnsafeMutablePointer<GtkWidget>,
        window: UnsafeMutablePointer<GtkWidget>
    ) {
        Gtk.removeChildren(of: slot)
        let package = AnalyticsShare(analytics)
        let windowBits = UInt(bitPattern: window)
        let copy = Gtk.button(Localized.text("Copy card")) {
            if let png = AnalyticsCardRenderer.png(package) {
                png.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    tailscode_clipboard_set_text_and_image_png(
                        package.plainText, base, gsize(png.count))
                }
            } else {
                Gtk.copyToClipboard(package.plainText)
            }
        }
        let save = Gtk.button(Localized.text("Save image…")) {
            guard let png = AnalyticsCardRenderer.png(package),
                let windowRaw = UnsafeMutableRawPointer(bitPattern: windowBits)
            else { return }
            Gtk.saveFile(
                parent: ptr(windowRaw), suggestedName: package.filename, data: png
            ) { _ in }
        }
        gtk_box_append(ptr(slot), copy)
        gtk_box_append(ptr(slot), save)
    }

    /// Every server the app knows, asked for its whole ledger — every model the person runs
    /// belongs in the month whichever agent served it. A server that answers nil is too old for
    /// the route and is named rather than silently dropped; one that cannot be reached at all is
    /// left to the surfaces that already report reachability.
    private static func gather(window: UsageWindow) async -> UsageAnalytics? {
        let profiles = await ServerDirectory.shared.profiles()
        var reports: [(name: String, report: UsageAnalyticsReport)] = []
        var missing: [String] = []
        var seenHosts = Set<String>()
        for profile in profiles {
            let host = "\(profile.baseURL.host ?? profile.id):\(profile.baseURL.port ?? 0)"
            guard seenHosts.insert(host).inserted else { continue }
            guard let backend = await ServerDirectory.shared.backend(for: profile) else { continue }
            let name = ServerLabel.display(profile)
            do {
                if let report = try await backend.usageAnalytics(days: window.days) {
                    reports.append((name, report))
                } else {
                    missing.append(name)
                }
            } catch {
                continue
            }
        }
        return UsageAnalytics(servers: reports, missingServers: missing, window: window)
    }

    /// A state that is the whole window sits in the middle of it, not in a corner.
    private static func notice(_ text: String) -> UnsafeMutablePointer<GtkWidget> {
        let label = Gtk.label(text, css: "dim", selectable: false)
        gtk_widget_set_halign(label, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(label, GTK_ALIGN_CENTER)
        gtk_widget_set_vexpand(label, 1)
        return label
    }

    private static func render(
        _ analytics: UsageAnalytics?, into column: UnsafeMutablePointer<GtkWidget>
    ) {
        Gtk.removeChildren(of: column)
        guard let analytics else {
            gtk_box_append(ptr(column), notice(Localized.text("Nothing on the ledger yet.")))
            return
        }
        gtk_box_append(ptr(column), hero(analytics))
        if !analytics.days.isEmpty { gtk_box_append(ptr(column), daily(analytics)) }
        if analytics.weekdays.contains(where: { $0.share > 0 }) || !analytics.hours.isEmpty {
            gtk_box_append(ptr(column), rhythm(analytics))
        }
        if !analytics.providers.isEmpty {
            gtk_box_append(
                ptr(column),
                meterCard(
                    title: Localized.text("Providers"), meters: analytics.providers, caption: nil))
        }
        if !analytics.models.isEmpty {
            gtk_box_append(
                ptr(column),
                meterCard(
                    title: Localized.text("Models"), meters: analytics.models,
                    caption: analytics.modelsLine))
        }
        if !analytics.projects.isEmpty {
            gtk_box_append(
                ptr(column),
                meterCard(
                    title: Localized.text("Projects"), meters: analytics.projects, caption: nil))
        }
        if !analytics.tools.isEmpty {
            gtk_box_append(
                ptr(column),
                meterCard(
                    title: Localized.text("Tools"), meters: analytics.tools,
                    caption: analytics.toolsLine))
        }
        if !analytics.tiers.isEmpty { gtk_box_append(ptr(column), tiers(analytics)) }
        if !analytics.records.isEmpty { gtk_box_append(ptr(column), records(analytics)) }
        if !analytics.machines.isEmpty {
            gtk_box_append(
                ptr(column),
                meterCard(
                    title: Localized.text("Machines"), meters: analytics.machines, caption: nil))
        }
        gtk_box_append(ptr(column), footer(analytics))
    }

    /// The span is picked where the number it qualifies is: a total with no window on it is not a
    /// fact, and the two belong in the same glance. Rebuilt with the card, so the pressed one is
    /// always the one being read.
    private static func windowPicker() -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        Gtk.addClass(row, "linked")
        gtk_widget_set_halign(row, GTK_ALIGN_START)
        for span in UsageWindow.allCases {
            let chosen = span == UsageWindow.current
            let button = Gtk.button(span.title, css: chosen ? ["suggested-action"] : []) {
                guard span != UsageWindow.current else { return }
                UsageWindow.current = span
                SettingsFile.capture()
                if let raw = UnsafeMutableRawPointer(bitPattern: openWindow) {
                    gtk_window_set_title(ptr(raw), span.surfaceTitle)
                }
                load()
            }
            gtk_widget_set_sensitive(button, chosen ? 0 : 1)
            gtk_box_append(ptr(row), button)
        }
        return row
    }

    private static func hero(_ analytics: UsageAnalytics) -> UnsafeMutablePointer<GtkWidget> {
        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
        Gtk.addClass(card, "usage-card")
        gtk_box_append(ptr(card), windowPicker())
        gtk_box_append(
            ptr(card), Gtk.label(analytics.windowLabel, css: "usage-plan", selectable: false))
        let money = Gtk.label(analytics.headline, css: "analytics-total", selectable: false)
        gtk_label_set_ellipsize(op(money), PANGO_ELLIPSIZE_NONE)
        gtk_box_append(ptr(card), money)
        gtk_box_append(
            ptr(card), Gtk.label(analytics.perDayLine, css: "usage-detail-key", selectable: false))
        let activity = Gtk.label(
            analytics.activityLine, css: "usage-detail-key", wrap: true, selectable: false)
        gtk_box_append(ptr(card), activity)
        if let delta = analytics.deltaLine {
            let tone: String
            switch analytics.trend {
            case .up: tone = "analytics-delta-up"
            case .down: tone = "analytics-delta-down"
            case .flat: tone = "analytics-delta-flat"
            }
            gtk_box_append(ptr(card), Gtk.label(delta, css: tone, selectable: false))
        }
        return card
    }

    private static func daily(_ analytics: UsageAnalytics) -> UnsafeMutablePointer<GtkWidget> {
        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        Gtk.addClass(card, "usage-card")
        gtk_box_append(
            ptr(card), heading(analytics.window.chartTitle, trailing: analytics.windowLabel))

        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 2)
        gtk_widget_set_valign(row, GTK_ALIGN_END)
        gtk_widget_set_size_request(row, -1, Int32(dayChartHeight))
        // Thirteen months and thirty days are the same chart at different grains, and a column
        // sized for the denser one leaves the coarser one a row of pins across a wide card.
        let barWidth = analytics.days.count <= 16 ? 34 : dayBarWidth
        for day in analytics.days {
            let holder = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
            gtk_widget_set_valign(holder, GTK_ALIGN_END)
            let bar = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
            Gtk.addClass(bar, day.isToday ? "analytics-bar-today" : "analytics-bar")
            let height = max(2, Int(Double(dayChartHeight) * min(max(day.share, 0), 1)))
            gtk_widget_set_size_request(bar, Int32(barWidth), Int32(height))
            var tip = "\(day.title) · \(day.value)"
            if day.turns > 0 { tip += " · " + Localized.text("%@ turns", "\(day.turns)") }
            gtk_widget_set_tooltip_text(bar, tip)
            gtk_box_append(ptr(holder), bar)
            gtk_box_append(ptr(row), holder)
        }
        gtk_box_append(ptr(card), row)

        let captions = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        if let peak = analytics.peakDay, peak.share > 0 {
            let left = Gtk.label(
                Localized.text("Peak %@ · %@", peak.title, peak.value),
                css: "spend-caption", selectable: false)
            gtk_label_set_ellipsize(op(left), PANGO_ELLIPSIZE_NONE)
            gtk_widget_set_hexpand(left, 1)
            gtk_box_append(ptr(captions), left)
        }
        if let today = analytics.days.last(where: \.isToday) {
            let right = Gtk.label(
                Localized.text("Today · %@", today.value), css: "spend-caption", selectable: false)
            gtk_label_set_ellipsize(op(right), PANGO_ELLIPSIZE_NONE)
            gtk_box_append(ptr(captions), right)
        }
        gtk_box_append(ptr(card), captions)
        return card
    }

    private static func rhythm(_ analytics: UsageAnalytics) -> UnsafeMutablePointer<GtkWidget> {
        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
        Gtk.addClass(card, "usage-card")
        gtk_box_append(ptr(card), heading(Localized.text("Rhythm"), trailing: nil))

        if analytics.weekdays.contains(where: { $0.share > 0 }) {
            let week = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
            gtk_widget_set_valign(week, GTK_ALIGN_END)
            for weekday in analytics.weekdays {
                let columnBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 3)
                gtk_widget_set_valign(columnBox, GTK_ALIGN_END)
                let bar = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
                Gtk.addClass(bar, "analytics-bar")
                let height = max(
                    2, Int(Double(weekdayChartHeight) * min(max(weekday.share, 0), 1)))
                gtk_widget_set_size_request(bar, Int32(weekdayBarWidth), Int32(height))
                if let money = weekday.money { gtk_widget_set_tooltip_text(bar, money) }
                gtk_box_append(ptr(columnBox), bar)
                let label = Gtk.label(weekday.label, css: "spend-caption", selectable: false)
                gtk_label_set_ellipsize(op(label), PANGO_ELLIPSIZE_NONE)
                gtk_label_set_xalign(op(label), 0.5)
                gtk_box_append(ptr(columnBox), label)
                gtk_box_append(ptr(week), columnBox)
            }
            gtk_box_append(ptr(card), week)
        }

        if !analytics.hours.isEmpty {
            let clock = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 2)
            gtk_widget_set_valign(clock, GTK_ALIGN_END)
            gtk_widget_set_size_request(clock, -1, Int32(hourChartHeight))
            Gtk.margins(clock, top: 4)
            for hour in analytics.hours {
                let holder = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
                gtk_widget_set_valign(holder, GTK_ALIGN_END)
                let bar = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
                Gtk.addClass(bar, "analytics-hour")
                let height = max(2, Int(Double(hourChartHeight) * min(max(hour.share, 0), 1)))
                gtk_widget_set_size_request(bar, Int32(hourBarWidth), Int32(height))
                gtk_widget_set_tooltip_text(
                    bar, "\(hour.label):00 · " + Localized.text("%@ turns", "\(hour.turns)"))
                gtk_box_append(ptr(holder), bar)
                gtk_box_append(ptr(clock), holder)
            }
            gtk_box_append(ptr(card), clock)
        }

        if let clockLine = analytics.clockLine {
            gtk_box_append(
                ptr(card), Gtk.label(clockLine, css: "spend-caption", selectable: false))
        }
        return card
    }

    private static func meterCard(
        title: String, meters: [UsageAnalytics.Meter], caption: String?
    ) -> UnsafeMutablePointer<GtkWidget> {
        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        Gtk.addClass(card, "usage-card")
        gtk_box_append(ptr(card), heading(title, trailing: nil))
        for row in meters {
            gtk_box_append(
                ptr(card),
                meter(
                    label: row.label, value: row.money, detail: row.detail, fraction: row.share,
                    hot: false, free: row.isFree))
        }
        if let caption {
            gtk_box_append(
                ptr(card),
                Gtk.label(caption, css: "spend-caption", wrap: true, selectable: false))
        }
        return card
    }

    private static func tiers(_ analytics: UsageAnalytics) -> UnsafeMutablePointer<GtkWidget> {
        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        Gtk.addClass(card, "usage-card")
        gtk_box_append(ptr(card), heading(Localized.text("Where it went"), trailing: nil))
        for tier in analytics.tiers {
            gtk_box_append(
                ptr(card),
                meter(
                    label: tier.label, value: SessionSpend.money(tier.costUSD),
                    detail: StatusFacts.tokens(tier.tokens), fraction: tier.share,
                    hot: tier.id == "output"))
        }
        if let cacheLine = analytics.cacheLine {
            gtk_box_append(
                ptr(card), Gtk.label(cacheLine, css: "spend-caption", selectable: false))
        }
        return card
    }

    private static func records(_ analytics: UsageAnalytics) -> UnsafeMutablePointer<GtkWidget> {
        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        Gtk.addClass(card, "usage-card")
        gtk_box_append(ptr(card), heading(Localized.text("Records"), trailing: nil))
        var index = 0
        while index < analytics.records.count {
            let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
            gtk_box_set_homogeneous(ptr(row), 1)
            gtk_box_append(ptr(row), recordCard(analytics.records[index]))
            if index + 1 < analytics.records.count {
                gtk_box_append(ptr(row), recordCard(analytics.records[index + 1]))
            } else {
                let filler = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
                gtk_box_append(ptr(row), filler)
            }
            gtk_box_append(ptr(card), row)
            index += 2
        }
        return card
    }

    private static func recordCard(_ record: UsageAnalytics.Record)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let cell = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        Gtk.addClass(cell, "record-card")
        let glyph = Gtk.label(record.glyph, css: "record-glyph", selectable: false)
        gtk_label_set_ellipsize(op(glyph), PANGO_ELLIPSIZE_NONE)
        gtk_box_append(ptr(cell), glyph)
        let title = Gtk.label(record.title.uppercased(), css: "record-title", selectable: false)
        gtk_label_set_ellipsize(op(title), PANGO_ELLIPSIZE_NONE)
        gtk_box_append(ptr(cell), title)
        let value = Gtk.label(record.value, css: "record-value", selectable: false)
        gtk_box_append(ptr(cell), value)
        if let detail = record.detail {
            let text = Gtk.label(detail, css: "record-detail", wrap: true, selectable: false)
            gtk_label_set_ellipsize(op(text), PANGO_ELLIPSIZE_END)
            gtk_label_set_lines(op(text), 2)
            gtk_box_append(ptr(cell), text)
        }
        return cell
    }

    private static func footer(_ analytics: UsageAnalytics) -> UnsafeMutablePointer<GtkWidget> {
        let block = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
        for insight in analytics.insights {
            gtk_box_append(
                ptr(block),
                Gtk.label("· " + insight, css: "usage-detail-key", wrap: true, selectable: false))
        }
        if let coverageNote = analytics.coverageNote {
            gtk_box_append(
                ptr(block),
                Gtk.label(coverageNote, css: "usage-source", wrap: true, selectable: false))
        }
        gtk_box_append(
            ptr(block), Gtk.label(analytics.source, css: "usage-source", selectable: false))
        if !analytics.missingServers.isEmpty {
            gtk_box_append(
                ptr(block),
                Gtk.label(
                    Localized.text(
                        "Not counted: %@ (server too old)",
                        analytics.missingServers.joined(separator: ", ")),
                    css: "usage-source", wrap: true, selectable: false))
        }
        return block
    }

    private static func heading(_ text: String, trailing: String?)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let title = Gtk.label(text, css: "usage-provider", selectable: false)
        gtk_label_set_xalign(op(title), 0)
        gtk_widget_set_hexpand(title, 1)
        gtk_box_append(ptr(row), title)
        if let trailing {
            let caption = Gtk.label(trailing, css: "spend-caption", selectable: false)
            gtk_label_set_ellipsize(op(caption), PANGO_ELLIPSIZE_NONE)
            gtk_box_append(ptr(row), caption)
        }
        return row
    }

    private static func meter(
        label: String, value: String?, detail: String, fraction: Double, hot: Bool,
        free: Bool = false
    ) -> UnsafeMutablePointer<GtkWidget> {
        let block = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 3)
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let name = Gtk.label(label, css: "usage-gauge-label", selectable: false)
        gtk_label_set_xalign(op(name), 0)
        gtk_widget_set_hexpand(name, 1)
        gtk_box_append(ptr(row), name)
        if !detail.isEmpty {
            let count = Gtk.label(detail, css: "spend-caption", selectable: false)
            gtk_label_set_ellipsize(op(count), PANGO_ELLIPSIZE_NONE)
            gtk_box_append(ptr(row), count)
        }
        if let value {
            let money = Gtk.label(
                value, css: free ? "analytics-free" : "usage-detail-value", selectable: false)
            gtk_label_set_ellipsize(op(money), PANGO_ELLIPSIZE_NONE)
            gtk_box_append(ptr(row), money)
        }
        gtk_box_append(ptr(block), row)

        let track = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        Gtk.addClass(track, "gauge-track")
        gtk_widget_set_size_request(track, Int32(meterTrack), 6)
        gtk_widget_set_halign(track, GTK_ALIGN_START)
        let fill = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        Gtk.addClass(fill, hot ? "spend-bar-hot" : "spend-bar")
        let width = max(2, Int(Double(meterTrack) * min(max(fraction, 0), 1)))
        gtk_widget_set_size_request(fill, Int32(width), 6)
        gtk_widget_set_halign(fill, GTK_ALIGN_START)
        gtk_box_append(ptr(track), fill)
        gtk_box_append(ptr(block), track)
        return block
    }
}
