import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// A widget held by something that may outlive it. GObject clears the reference the moment the
/// widget is disposed, so a fetch that lands after its row was torn down finds nothing and
/// touches nothing, instead of writing into memory GTK has already given back.
final class WidgetRef: @unchecked Sendable {
    private let slot: UnsafeMutablePointer<GWeakRef>

    init(_ widget: UnsafeMutablePointer<GtkWidget>) {
        slot = .allocate(capacity: 1)
        g_weak_ref_init(slot, UnsafeMutableRawPointer(widget))
    }

    deinit {
        g_weak_ref_clear(slot)
        slot.deallocate()
    }

    var isAlive: Bool {
        guard let strong = g_weak_ref_get(slot) else { return false }
        g_object_unref(strong)
        return true
    }

    /// Runs `body` on the widget if it is still there, holding it alive for the duration.
    func with(_ body: (UnsafeMutablePointer<GtkWidget>) -> Void) {
        guard let strong = g_weak_ref_get(slot) else { return }
        body(strong.assumingMemoryBound(to: GtkWidget.self))
        g_object_unref(strong)
    }
}

extension LinkRailReading {
    /// A rail with exactly one address has nothing to expand: it is the link itself, opened by a
    /// press, with no plate and no chevron.
    var opensDirectlyHere: Bool { count == 1 }

    /// What a screen reader is told of a rail that is one link: its title and that it is a link,
    /// where a longer rail is a disclosure button.
    var spokenAsLink: String {
        Localized.text("%@, link", items.first?.face.headline ?? "")
    }
}

/// What the rail line and its plate share: the addresses, the faces fetched so far, the fetches
/// that have gone out and the widgets a landing fetch writes into. Touched only on the GLib main
/// context. It lives as long as the rail widget does and no longer — the widget's destruction
/// cancels every fetch and drops it from the registry.
final class LinkRailModel: @unchecked Sendable {
    let id: Int
    let key: String
    let urls: [String]
    let source: LinkCardSource
    let toast: (@Sendable (String) -> Void)?
    private(set) var reading: LinkRailReading
    private(set) var isOpen = false
    private var fetches = LinkRailFetches()
    private var tasks: [Task<Void, Never>] = []
    fileprivate(set) var line: LinkRailLine?
    fileprivate(set) var plateRows: [String: LinkPlateRow] = [:]

    init(
        id: Int, key: String, urls: [String], source: LinkCardSource,
        toast: (@Sendable (String) -> Void)?
    ) {
        self.id = id
        self.key = key
        self.urls = urls
        self.source = source
        self.toast = toast
        let held = LinkRailReading.placeholder(for: urls)
        var reading = held
        for url in urls {
            if let face = source.cachedFace(url) { reading = reading.replacing(face, for: url) }
        }
        self.reading = reading
    }

    deinit {
        for task in tasks { task.cancel() }
    }

    func cancelFetches() {
        for task in tasks { task.cancel() }
        tasks = []
    }

    /// Asks about the addresses the plan names that nothing has asked about yet: the stack when the
    /// rail is made, the rest the first time it is opened.
    func fetch(opened: Bool) {
        for url in fetches.claim(for: urls, opened: opened) {
            guard let line, let address = URL(string: url) else { continue }
            let anchor = WidgetRef(line.widget)
            let known = source.cachedFace(url) != nil
            let task = Task { [self] in
                if !known {
                    let wanted = await LinkEmbedPolicy.settle(debounce: source.debounce) {
                        anchor.isAlive
                    }
                    guard wanted else { return }
                    let metadata = await source.metadata(url)
                    guard !Task.isCancelled else { return }
                    let face = LinkCardFace.settled(for: address, metadata: metadata)
                    Gtk.onMain { [self] in land(face, for: url) }
                }
                await paintIcon(for: url, anchor: anchor)
            }
            tasks.append(task)
        }
    }

    fileprivate func land(_ face: LinkCardFace, for url: String) {
        reading = reading.replacing(face, for: url)
        line?.apply(reading, expanded: isOpen)
        plateRows[url]?.apply(face)
    }

    func setOpen(_ open: Bool) {
        isOpen = open
        line?.apply(reading, expanded: open)
        if !open { plateRows = [:] }
    }

    fileprivate func registerPlate(rows: [String: LinkPlateRow]) {
        plateRows = rows
    }

    /// The page's own icon, once it is known and decodable, in place of the glyph. Decoding stays
    /// off the GLib main context; the picture is made where GTK lives, in the same hop that reads or
    /// fills the shared texture cache, so an eviction cannot land between the two.
    private func paintIcon(for url: String, anchor: WidgetRef) async {
        let cached = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            Gtk.onMain { [self] in
                let bits = MediaImageCache.shared.texture(for: url)
                if bits != 0 { iconLanded(for: url) }
                continuation.resume(returning: bits != 0)
            }
        }
        guard !cached, anchor.isAlive else { return }
        guard let data = await source.favicon(url), !Task.isCancelled else { return }
        let bits = MediaImageCache.decode(data)
        guard bits != 0 else { return }
        Gtk.onMain { [self] in
            MediaImageCache.shared.store(bits, for: url)
            iconLanded(for: url)
        }
    }

    /// Puts the cached icon of an address wherever that address is drawn right now.
    fileprivate func iconLanded(for url: String) {
        let bits = MediaImageCache.shared.texture(for: url)
        guard bits != 0 else { return }
        line?.place(bits, for: url)
        plateRows[url]?.place(bits)
    }

    func copyAll() {
        Gtk.copyToClipboard(reading.copyAllText)
        toast?(Localized.text("Link copied."))
    }

    func openAll(from widget: UnsafeMutablePointer<GtkWidget>) {
        for url in urls { tailscode_open_uri(widget, url) }
    }

    func copy(_ url: String) {
        Gtk.copyToClipboard(url)
        toast?(Localized.text("Link copied."))
    }
}

/// The rail's own widgets, which a landing fetch writes into. Every one exists from the first
/// frame — the favicon seats, the host line, the count, the chevron — so the line is the same
/// height and the same shape at every stage of its life and a fetch landing moves nothing.
final class LinkRailLine: @unchecked Sendable {
    let widget: UnsafeMutablePointer<GtkWidget>
    let icons: [UnsafeMutablePointer<GtkWidget>]
    let hosts: UnsafeMutablePointer<GtkWidget>
    let afterTitle: UnsafeMutablePointer<GtkWidget>
    let more: UnsafeMutablePointer<GtkWidget>
    let chevron: UnsafeMutablePointer<GtkWidget>
    private let stackedURLs: [String]

    init(
        widget: UnsafeMutablePointer<GtkWidget>, icons: [UnsafeMutablePointer<GtkWidget>],
        stackedURLs: [String], hosts: UnsafeMutablePointer<GtkWidget>,
        afterTitle: UnsafeMutablePointer<GtkWidget>, more: UnsafeMutablePointer<GtkWidget>,
        chevron: UnsafeMutablePointer<GtkWidget>
    ) {
        self.widget = widget
        self.icons = icons
        self.stackedURLs = stackedURLs
        self.hosts = hosts
        self.afterTitle = afterTitle
        self.more = more
        self.chevron = chevron
    }

    /// Writes a reading into the line: the hosts of the stack, or for one address its title with
    /// the host after it, the count of the rest, the chevron's direction, and what a screen reader
    /// is told.
    func apply(_ reading: LinkRailReading, expanded: Bool) {
        if let title = reading.singleTitle, let item = reading.items.first {
            gtk_label_set_text(op(hosts), title)
            let showsHost = !item.face.headlineIsQuiet
            gtk_label_set_text(op(afterTitle), showsHost ? item.face.host : "")
            gtk_widget_set_visible(afterTitle, showsHost ? 1 : 0)
        } else {
            gtk_label_set_text(op(hosts), reading.hostsLine)
            gtk_widget_set_visible(afterTitle, 0)
        }
        if let label = reading.moreLabel {
            gtk_label_set_text(op(more), label)
            gtk_widget_set_visible(more, 1)
        } else {
            gtk_widget_set_visible(more, 0)
        }
        let direct = reading.opensDirectlyHere
        gtk_label_set_text(op(chevron), direct ? "↗" : expanded ? "⌄" : "›")
        if expanded {
            gtk_widget_add_css_class(widget, "link-rail-open")
        } else {
            gtk_widget_remove_css_class(widget, "link-rail-open")
        }
        tailscode_set_accessible_label(
            widget, direct ? reading.spokenAsLink : reading.spoken(expanded: expanded))
    }

    func place(_ bits: UInt, for url: String) {
        guard let index = stackedURLs.firstIndex(of: url), index < icons.count else { return }
        LinkRailView.fill(icons[index], with: bits, size: LinkRailView.stackIconSize)
    }
}

/// One address of the opened plate: its row's own title and host labels and its icon seat.
final class LinkPlateRow: @unchecked Sendable {
    let title: WidgetRef
    let host: WidgetRef
    let icon: WidgetRef

    init(
        title: UnsafeMutablePointer<GtkWidget>, host: UnsafeMutablePointer<GtkWidget>,
        icon: UnsafeMutablePointer<GtkWidget>
    ) {
        self.title = WidgetRef(title)
        self.host = WidgetRef(host)
        self.icon = WidgetRef(icon)
    }

    func apply(_ face: LinkCardFace) {
        title.with { gtk_label_set_text(op($0), face.headline) }
        host.with { gtk_label_set_text(op($0), face.caption) }
    }

    func place(_ bits: UInt) {
        icon.with { LinkRailView.fill($0, with: bits, size: LinkRailView.plateIconSize) }
    }
}

/// Which rails are on screen, by widget, so the one pointer watch on the transcript can say which
/// rail the pointer is over without a controller per row.
final class LinkRailRegistry: @unchecked Sendable {
    nonisolated(unsafe) static let shared = LinkRailRegistry()
    private var byID: [Int: LinkRailModel] = [:]
    private var nextID = 1

    func make(
        key: String, urls: [String], source: LinkCardSource,
        toast: (@Sendable (String) -> Void)?
    ) -> LinkRailModel {
        let model = LinkRailModel(id: nextID, key: key, urls: urls, source: source, toast: toast)
        nextID += 1
        byID[model.id] = model
        return model
    }

    func model(_ id: Int) -> LinkRailModel? { byID[id] }

    func remove(_ id: Int) { byID[id] = nil }

    var count: Int { byID.count }
}

/// The link rail: one 24-pixel line under the prose that mentioned the addresses — up to three
/// overlapping favicons, the hosts in link ink, a count for the rest and a quiet chevron — with
/// every word Core's (`LinkRailReading`). It carries no plate: the plate is one widget the
/// transcript owns and floats over its neighbours, so opening it moves no row.
enum LinkRailView {
    static let stackIconSize: Int32 = 14
    static let plateIconSize: Int32 = 16
    private static let overlap: Int32 = 4
    static let idKey = "tailscode-rail-id"

    struct Parts {
        let widget: UnsafeMutablePointer<GtkWidget>
        let line: LinkRailLine
        let model: LinkRailModel
    }

    static func make(
        urls: [String], key: String, context: TranscriptContext?, source: LinkCardSource = .live
    ) -> UnsafeMutablePointer<GtkWidget> {
        build(urls: urls, key: key, context: context, source: source).widget
    }

    static func build(
        urls: [String], key: String, context: TranscriptContext?, source: LinkCardSource
    ) -> Parts {
        let model = LinkRailRegistry.shared.make(
            key: key, urls: urls, source: source, toast: context?.toast)
        let direct = model.reading.opensDirectlyHere
        let widget = tailscode_box_new_with_role(
            GTK_ORIENTATION_HORIZONTAL, 6,
            direct ? GTK_ACCESSIBLE_ROLE_LINK : GTK_ACCESSIBLE_ROLE_BUTTON)!
        Gtk.addClass(widget, "link-rail")
        gtk_widget_set_halign(widget, GTK_ALIGN_START)
        gtk_widget_set_size_request(widget, -1, Int32(ChatMetrics.metrics(for: Preferences.chatDensity, input: .pointer).railRowHeight))
        gtk_widget_set_focusable(widget, 1)
        gtk_widget_set_can_focus(widget, 1)
        gtk_widget_set_cursor_from_name(widget, "pointer")
        g_object_set_data(
            ptr(UnsafeMutableRawPointer(widget)), idKey, UnsafeMutableRawPointer(bitPattern: model.id))

        let stacked = Array(model.reading.stack.map(\.url))
        let seats = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        let fixed = gtk_fixed_new()!
        var icons: [UnsafeMutablePointer<GtkWidget>] = []
        for (index, url) in stacked.enumerated() {
            let seat = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
            Gtk.addClass(seat, "link-rail-icon")
            gtk_widget_set_size_request(seat, stackIconSize, stackIconSize)
            gtk_widget_set_overflow(seat, GTK_OVERFLOW_HIDDEN)
            gtk_box_append(ptr(seat), glyph(for: url))
            gtk_fixed_put(
                ptr(UnsafeMutableRawPointer(fixed)), seat,
                Double(Int32(index) * (stackIconSize - overlap)), 0)
            icons.append(seat)
        }
        let count = Int32(max(1, stacked.count))
        gtk_widget_set_size_request(fixed, stackIconSize + (count - 1) * (stackIconSize - overlap), stackIconSize)
        gtk_widget_set_valign(fixed, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(seats), fixed)
        gtk_box_append(ptr(widget), seats)

        let hosts = Gtk.label("", css: "link-rail-host", selectable: false)
        gtk_label_set_ellipsize(op(hosts), PANGO_ELLIPSIZE_END)
        gtk_label_set_single_line_mode(op(hosts), 1)
        gtk_label_set_max_width_chars(op(hosts), 90)
        gtk_widget_set_valign(hosts, GTK_ALIGN_CENTER)
        let afterTitle = Gtk.label("", css: "link-rail-more", selectable: false)
        gtk_label_set_ellipsize(op(afterTitle), PANGO_ELLIPSIZE_END)
        gtk_label_set_single_line_mode(op(afterTitle), 1)
        gtk_widget_set_valign(afterTitle, GTK_ALIGN_CENTER)
        let more = Gtk.label("", css: "link-rail-more", selectable: false)
        gtk_widget_set_valign(more, GTK_ALIGN_CENTER)
        let chevron = Gtk.label("›", css: "link-rail-chevron", selectable: false)
        gtk_widget_set_valign(chevron, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(widget), hosts)
        gtk_box_append(ptr(widget), afterTitle)
        gtk_box_append(ptr(widget), more)
        gtk_box_append(ptr(widget), chevron)

        let line = LinkRailLine(
            widget: widget, icons: icons, stackedURLs: stacked, hosts: hosts,
            afterTitle: afterTitle, more: more, chevron: chevron)
        model.line = line
        line.apply(model.reading, expanded: false)
        for url in stacked { model.iconLanded(for: url) }
        model.fetch(opened: false)

        let id = model.id
        let act = context?.railAct
        let widgetRef = WidgetRef(widget)
        Gtk.onPrimaryRelease(widget) {
            if direct {
                widgetRef.with { follow(model, from: $0) }
            } else {
                act?(id, .click)
            }
        }
        Gtk.onRightClick(widget) { x, y in
            widgetRef.with { widget in
                Gtk.contextMenu(on: widget, x: x, y: y, rows: menuRows(model: model, ref: widgetRef))
            }
        }
        Gtk.onKey(widget) { keyval, _ in
            switch keyval {
            case 0x20, Keymap.enter, Keymap.keypadEnter:
                if direct {
                    widgetRef.with { follow(model, from: $0) }
                } else {
                    act?(id, .key)
                }
                return true
            case Keymap.down where !direct:
                act?(id, .down)
                return true
            default:
                return false
            }
        }
        Gtk.connect(UnsafeMutableRawPointer(widget), "destroy") {
            model.cancelFetches()
            context?.railGone?(id)
            LinkRailRegistry.shared.remove(id)
        }
        return Parts(widget: widget, line: line, model: model)
    }

    /// A press on a rail that is one link: the address opens where a link in the prose opens, or
    /// is copied when control is held.
    static func follow(_ model: LinkRailModel, from widget: UnsafeMutablePointer<GtkWidget>) {
        guard let url = model.urls.first else { return }
        if Gtk.ctrlHeld(widget) {
            model.copy(url)
        } else {
            tailscode_open_uri(widget, url)
        }
    }

    /// What the rail's own menu offers: for one link, its address copied; for a longer rail every
    /// address copied, or every address opened.
    static func menuRows(
        model: LinkRailModel, ref: WidgetRef
    ) -> [(title: String, detail: String?, action: @Sendable () -> Void)] {
        if model.reading.opensDirectlyHere, let url = model.urls.first {
            return [(title: Localized.text("Copy address"), detail: nil, action: { model.copy(url) })]
        }
        return [
            (title: LinkRailReading.copyAllTitle, detail: nil, action: { model.copyAll() }),
            (title: LinkRailReading.openAllTitle, detail: nil,
                action: { ref.with { model.openAll(from: $0) } }),
        ]
    }

    /// The host's initial until the page's own icon is known.
    private static func glyph(for url: String) -> UnsafeMutablePointer<GtkWidget> {
        let host = URL(string: url)?.host ?? url
        let trimmed = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let letter = trimmed.first.map { String($0).uppercased() } ?? "·"
        let mark = Gtk.label(letter, css: "link-rail-glyph", selectable: false)
        gtk_widget_set_halign(mark, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(mark, GTK_ALIGN_CENTER)
        gtk_widget_set_hexpand(mark, 1)
        gtk_widget_set_vexpand(mark, 1)
        return mark
    }

    /// A decoded icon in a seat, through the surface-paintable helper — never a raw texture handed
    /// to a `GtkPicture`.
    static func fill(_ seat: UnsafeMutablePointer<GtkWidget>, with bits: UInt, size: Int32) {
        guard let picture = MediaImageCache.shared.picture(bits, width: size, height: size)
        else { return }
        gtk_picture_set_content_fit(op(picture), GTK_CONTENT_FIT_CONTAIN)
        Gtk.removeChildren(of: seat)
        gtk_box_append(ptr(seat), picture)
        gtk_widget_add_css_class(seat, "link-rail-icon-loaded")
    }

    /// The seat of an address on the plate: the host's initial until its icon is there.
    static func plateSeat(for url: String, cached bits: UInt) -> UnsafeMutablePointer<GtkWidget> {
        let seat = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        Gtk.addClass(seat, "link-rail-icon")
        gtk_widget_set_size_request(seat, plateIconSize, plateIconSize)
        gtk_widget_set_overflow(seat, GTK_OVERFLOW_HIDDEN)
        gtk_widget_set_valign(seat, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(seat), glyph(for: url))
        if bits != 0 { fill(seat, with: bits, size: plateIconSize) }
        return seat
    }

    static func railID(of widget: UnsafeMutablePointer<GtkWidget>) -> Int? {
        let raw = g_object_get_data(ptr(UnsafeMutableRawPointer(widget)), idKey)
        let id = Int(bitPattern: raw)
        return id == 0 ? nil : id
    }
}

/// The plate: a floating list of the rail's addresses, one 36-pixel row each, at most eight visible
/// and the rest reached by scrolling. It is one widget in the transcript's overlay that the
/// transcript's pointer watch shows and hides, never part of any row.
enum LinkRailPlateView {
    static let plateKey = "tailscode-rail-plate"

    struct Built {
        let content: UnsafeMutablePointer<GtkWidget>
        let rows: [UnsafeMutablePointer<GtkWidget>]
        let height: Double
    }

    /// The rows for a rail as it reads right now, and the plate's own widgets registered with the
    /// model so a fetch that lands while the plate is up rewrites the row it belongs to.
    static func build(
        model: LinkRailModel, metrics: ChatMetrics,
        menuAnchor: @escaping @Sendable () -> UnsafeMutablePointer<GtkWidget>?,
        menuOpen: @escaping @Sendable (Bool) -> Void
    ) -> Built {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        var registered: [String: LinkPlateRow] = [:]
        var rows: [UnsafeMutablePointer<GtkWidget>] = []
        for item in model.reading.items {
            let row = gtk_button_new()!
            Gtk.addClass(row, "flat")
            Gtk.addClass(row, "link-plate-row")
            gtk_widget_set_size_request(row, -1, Int32(metrics.railOpenRowHeight))
            let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
            let seat = LinkRailView.plateSeat(
                for: item.url, cached: MediaImageCache.shared.texture(for: item.url))
            gtk_box_append(ptr(line), seat)
            let title = Gtk.label(
                item.face.headline, css: "link-plate-title", selectable: false)
            gtk_label_set_ellipsize(op(title), PANGO_ELLIPSIZE_END)
            gtk_label_set_single_line_mode(op(title), 1)
            gtk_label_set_xalign(op(title), 0)
            gtk_widget_set_hexpand(title, 1)
            gtk_widget_set_halign(title, GTK_ALIGN_FILL)
            let host = Gtk.label(item.face.caption, css: "link-plate-host", selectable: false)
            gtk_label_set_ellipsize(op(host), PANGO_ELLIPSIZE_MIDDLE)
            gtk_label_set_single_line_mode(op(host), 1)
            gtk_label_set_max_width_chars(op(host), 28)
            gtk_box_append(ptr(line), title)
            gtk_box_append(ptr(line), host)
            gtk_button_set_child(ptr(row), line)
            gtk_widget_set_tooltip_text(row, item.url)
            gtk_widget_set_cursor_from_name(row, "pointer")
            tailscode_set_accessible_label(row, item.face.spoken)

            let url = item.url
            let rowRef = WidgetRef(row)
            Gtk.connect(UnsafeMutableRawPointer(row), "clicked") {
                rowRef.with { row in
                    if Gtk.ctrlHeld(row) {
                        model.copy(url)
                    } else {
                        tailscode_open_uri(row, url)
                    }
                }
            }
            Gtk.onRightClick(row) { x, y in
                guard let host = menuAnchor() else { return }
                rowRef.with { row in
                    var px = x
                    var py = y
                    if let box = Gtk.bounds(of: row, in: host) {
                        px += box.x
                        py += box.y
                    }
                    menuOpen(true)
                    Gtk.contextMenu(
                        on: host, x: px, y: py,
                        rows: [
                            (title: Localized.text("Copy address"), detail: nil,
                                action: { model.copy(url) })
                        ], onClosed: { menuOpen(false) })
                }
            }
            registered[item.url] = LinkPlateRow(title: title, host: host, icon: seat)
            gtk_box_append(ptr(column), row)
            rows.append(row)
        }
        model.registerPlate(rows: registered)

        let height = LinkRailPlate.plateHeight(rows: model.reading.count, metrics: metrics)
        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_propagate_natural_height(op(scroller), 1)
        gtk_scrolled_window_set_max_content_height(op(scroller), Int32(height))
        gtk_scrolled_window_set_child(op(scroller), column)
        return Built(content: scroller, rows: rows, height: height)
    }
}
