import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// The full quota picture behind the sidebar footer: the tightest window first as one tall bar,
/// then one card per provider, every gauge as a wide bar with its reset, spend windows in money,
/// and the account facts the provider reports. Opens on what the footer already knows, then
/// refetches so the numbers are current. The footer hands over to ``AnalyticsPanel`` for the
/// whole month.
enum UsagePanel {
    static let trackWidth = 300
    private static let heroTrackWidth = 314

    static func present(
        parent: UnsafeMutablePointer<GtkWidget>?,
        initial: [(String, UsageQuota)],
        refresh: @escaping @Sendable () async -> [(String, UsageQuota)]
    ) {
        let (window, content) = Dialogs.window(
            title: Localized.text("Usage"), parent: parent, width: 380)

        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 10)
        render(initial, into: column, refreshing: true)

        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_max_content_height(op(scroller), 640)
        gtk_scrolled_window_set_propagate_natural_height(op(scroller), 1)
        gtk_scrolled_window_set_child(op(scroller), column)
        gtk_box_append(ptr(content), scroller)

        let contentBits = UInt(bitPattern: content)
        let month = Gtk.button(Localized.text("The month in numbers"), css: ["analytics-open"]) {
            guard let raw = UnsafeMutableRawPointer(bitPattern: contentBits) else { return }
            AnalyticsPanel.present(parent: ptr(raw))
        }
        gtk_widget_set_hexpand(month, 1)
        gtk_box_append(ptr(content), month)

        let windowBits = UInt(bitPattern: window)
        let dismiss = Gtk.button(Localized.text("Close"), css: ["suggested-action"]) {
            guard let raw = UnsafeMutableRawPointer(bitPattern: windowBits) else { return }
            gtk_window_destroy(ptr(raw))
        }
        gtk_widget_set_halign(dismiss, GTK_ALIGN_END)
        Gtk.margins(dismiss, top: 4)
        gtk_box_append(ptr(content), dismiss)
        gtk_window_present(ptr(window))
        gtk_widget_grab_focus(dismiss)

        let columnBits = UInt(bitPattern: column)
        Task.detached {
            let fresh = await refresh()
            guard !fresh.isEmpty else { return }
            Gtk.onMain {
                guard let raw = UnsafeMutableRawPointer(bitPattern: columnBits) else { return }
                render(fresh, into: ptr(raw), refreshing: false)
            }
        }
    }

    private static func render(
        _ quotas: [(String, UsageQuota)], into column: UnsafeMutablePointer<GtkWidget>,
        refreshing: Bool
    ) {
        Gtk.removeChildren(of: column)
        guard !quotas.isEmpty else {
            gtk_box_append(
                ptr(column),
                Gtk.label(
                    refreshing
                        ? Localized.text("Asking the providers…")
                        : Localized.text("No provider reports a quota."),
                    css: "dim", selectable: false))
            return
        }
        if let pick = tightest(quotas) {
            gtk_box_append(ptr(column), hero(quota: pick.quota, gauge: pick.gauge))
        }
        for (server, quota) in quotas {
            gtk_box_append(ptr(column), card(server: server, quota: quota))
        }
        if refreshing {
            gtk_box_append(
                ptr(column), Gtk.label(Localized.text("Refreshing…"), css: "dim", selectable: false))
        }
    }

    /// The one number that decides what happens next: whichever window across every provider is
    /// closest to its wall, worn large with its own tall bar and its reset.
    private static func tightest(_ quotas: [(String, UsageQuota)])
        -> (quota: UsageQuota, gauge: UsageQuota.Gauge)?
    {
        var best: (quota: UsageQuota, gauge: UsageQuota.Gauge)?
        for (_, quota) in quotas {
            for gauge in quota.gauges where best.map({ gauge.fraction > $0.gauge.fraction }) ?? true {
                best = (quota, gauge)
            }
        }
        return best
    }

    private static func hero(quota: UsageQuota, gauge: UsageQuota.Gauge)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        Gtk.addClass(card, "usage-card")
        let fraction = min(max(gauge.fraction, 0), 1)
        let severity = fraction > 0.85 ? "danger" : fraction >= 0.6 ? "warn" : "ok"
        let slug = ProviderBrand.slug(quota.providerName)

        let header = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let name = Gtk.label(quota.providerName, css: "usage-provider", selectable: false)
        if let slug { Gtk.addClass(name, "brand-\(slug)") }
        gtk_box_append(ptr(header), name)
        gtk_box_append(ptr(header), Gtk.label(gauge.label, css: "usage-plan", selectable: false))
        gtk_box_append(ptr(card), header)

        let percent = Gtk.label(
            amount(for: gauge), css: "analytics-hero-percent", selectable: false)
        Gtk.addClass(percent, "hero-\(severity)")
        gtk_label_set_ellipsize(op(percent), PANGO_ELLIPSIZE_NONE)
        gtk_box_append(ptr(card), percent)

        let track = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        Gtk.addClass(track, "gauge-track")
        gtk_widget_set_size_request(track, Int32(heroTrackWidth), 10)
        gtk_widget_set_halign(track, GTK_ALIGN_START)
        let fill = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        Gtk.addClass(fill, ProviderBrand.fillClass(severity: severity, slug: slug))
        gtk_widget_set_size_request(fill, Int32((fraction * Double(heroTrackWidth)).rounded()), 10)
        gtk_widget_set_halign(fill, GTK_ALIGN_START)
        gtk_box_append(ptr(track), fill)
        gtk_box_append(ptr(card), track)

        if let resets = gauge.resetsAt {
            let phrasing =
                gauge.trustedReset
                ? Localized.text("resets in %@", countdown(to: resets))
                : Localized.text("resets in about %@", countdown(to: resets))
            gtk_box_append(ptr(card), Gtk.label(phrasing, css: "gauge-reset", selectable: false))
        }
        return card
    }

    private static func card(server: String, quota: UsageQuota) -> UnsafeMutablePointer<GtkWidget> {
        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
        Gtk.addClass(card, "usage-card")

        let header = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let name = Gtk.label(quota.providerName, css: "usage-provider", selectable: false)
        if let slug = ProviderBrand.slug(quota.providerName) {
            Gtk.addClass(name, "brand-\(slug)")
        }
        gtk_box_append(ptr(header), name)
        if !quota.subtitle.isEmpty {
            gtk_box_append(ptr(header), Gtk.label(quota.subtitle, css: "usage-plan", selectable: false))
        }
        let spacer = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_set_hexpand(spacer, 1)
        gtk_box_append(ptr(header), spacer)
        let badge = Gtk.label(
            quota.live ? Localized.text("LIVE") : Localized.text("CACHED"),
            css: quota.live ? "usage-live" : "usage-stale", selectable: false)
        gtk_label_set_ellipsize(op(badge), PANGO_ELLIPSIZE_NONE)
        gtk_box_append(ptr(header), badge)
        gtk_box_append(ptr(card), header)

        let slug = ProviderBrand.slug(quota.providerName)
        for gauge in quota.gauges {
            gtk_box_append(ptr(card), gaugeRows(gauge, slug: slug))
        }

        if !quota.details.isEmpty {
            let rule = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
            Gtk.addClass(rule, "usage-rule")
            gtk_box_append(ptr(card), rule)
            for detail in quota.details {
                let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
                let key = Gtk.label(detail.key, css: "usage-detail-key", selectable: false)
                gtk_widget_set_hexpand(key, 1)
                gtk_label_set_xalign(op(key), 0)
                gtk_box_append(ptr(row), key)
                gtk_box_append(
                    ptr(row), Gtk.label(detail.value, css: "usage-detail-value", selectable: false))
                gtk_box_append(ptr(card), row)
            }
        }

        gtk_box_append(
            ptr(card),
            Gtk.label("\(quota.source) · \(server)", css: "usage-source", selectable: false))
        return card
    }

    private static func gaugeRows(
        _ gauge: UsageQuota.Gauge, slug: String?
    ) -> UnsafeMutablePointer<GtkWidget> {
        let block = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 3)
        let fraction = min(max(gauge.fraction, 0), 1)
        let severity = fraction > 0.85 ? "danger" : fraction >= 0.6 ? "warn" : "ok"

        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let title = Gtk.label(gauge.label, css: "usage-gauge-label", selectable: false)
        gtk_widget_set_hexpand(title, 1)
        gtk_label_set_xalign(op(title), 0)
        gtk_label_set_ellipsize(op(title), PANGO_ELLIPSIZE_END)
        gtk_box_append(ptr(row), title)
        let amountLabel = Gtk.label(amount(for: gauge), css: "gauge-\(severity)", selectable: false)
        gtk_label_set_ellipsize(op(amountLabel), PANGO_ELLIPSIZE_NONE)
        gtk_box_append(ptr(row), amountLabel)
        gtk_box_append(ptr(block), row)

        let track = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        Gtk.addClass(track, "gauge-track")
        gtk_widget_set_size_request(track, Int32(trackWidth), 6)
        gtk_widget_set_halign(track, GTK_ALIGN_START)
        let fill = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        Gtk.addClass(fill, ProviderBrand.fillClass(severity: severity, slug: slug))
        gtk_widget_set_size_request(fill, Int32((fraction * Double(trackWidth)).rounded()), 6)
        gtk_box_append(ptr(track), fill)
        gtk_box_append(ptr(block), track)

        if let resets = gauge.resetsAt {
            let phrasing =
                gauge.trustedReset
                ? Localized.text("resets in %@", countdown(to: resets))
                : Localized.text("resets in about %@", countdown(to: resets))
            gtk_box_append(ptr(block), Gtk.label(phrasing, css: "gauge-reset", selectable: false))
        }
        return block
    }

    /// A spend window reads as money, everything else as the percent already used — or "Used up"
    /// when the window is at the wall.
    private static func amount(for gauge: UsageQuota.Gauge) -> String {
        if let used = gauge.usedUSD, let limit = gauge.limitUSD {
            return "$\(trimmed(used)) of $\(trimmed(limit))"
        }
        let percent = "\(Int((min(max(gauge.fraction, 0), 1) * 100).rounded()))%"
        return QuotaSurface.amountLabel(fraction: gauge.fraction, percentText: percent)
    }

    private static func trimmed(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }

    private static func countdown(to date: Date) -> String {
        let interval = date.timeIntervalSinceNow
        guard interval > 0 else { return Localized.text("moments") }
        let days = Int(interval) / 86400
        let hours = (Int(interval) % 86400) / 3600
        let minutes = (Int(interval) % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}
