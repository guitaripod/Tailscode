import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// A widget held by something that may outlive it. GObject clears the reference the moment the
/// widget is disposed, so a fetch that lands after its card was torn down finds nothing and
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

/// The preview card for an address a message mentioned: an icon slot, one line of title, one line
/// of host. Words are Core's `LinkCardFace`, the debounce and the fetch are Core's too; this draws
/// them and nothing more. A card never presents an address as a page nobody has read, and its
/// height does not change when the page answers — both lines exist from the first frame.
enum LinkCardView {
    static let iconSize: Int32 = 28
    private static let titleChars: Int32 = 56

    /// The card itself and the pieces its fetch will write into, which the self-test reads back.
    struct Parts {
        let card: UnsafeMutablePointer<GtkWidget>
        let title: UnsafeMutablePointer<GtkWidget>
        let host: UnsafeMutablePointer<GtkWidget>
        let iconSlot: UnsafeMutablePointer<GtkWidget>
        let task: Task<Void, Never>?
    }

    static func make(
        url: String, context: TranscriptContext?, source: LinkCardSource = .live
    ) -> UnsafeMutablePointer<GtkWidget> {
        build(url: url, context: context, source: source).card
    }

    static func build(
        url: String, context: TranscriptContext?, source: LinkCardSource
    ) -> Parts {
        let card = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        Gtk.addClass(card, "link-card")
        gtk_widget_set_halign(card, GTK_ALIGN_START)
        gtk_widget_set_tooltip_text(card, url)
        gtk_widget_set_cursor_from_name(card, "pointer")

        let iconSlot = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        Gtk.addClass(iconSlot, "link-card-icon")
        gtk_widget_set_size_request(iconSlot, iconSize, iconSize)
        gtk_widget_set_valign(iconSlot, GTK_ALIGN_CENTER)
        gtk_widget_set_overflow(iconSlot, GTK_OVERFLOW_HIDDEN)
        gtk_box_append(ptr(iconSlot), glyph())

        let title = Gtk.label("", css: "link-card-title", selectable: false)
        gtk_label_set_ellipsize(op(title), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(op(title), titleChars)
        gtk_label_set_single_line_mode(op(title), 1)
        let host = Gtk.label("", css: "link-card-host", selectable: false)
        gtk_label_set_ellipsize(op(host), PANGO_ELLIPSIZE_MIDDLE)
        gtk_label_set_max_width_chars(op(host), titleChars)
        gtk_label_set_single_line_mode(op(host), 1)
        let lines = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 1)
        gtk_widget_set_valign(lines, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(lines), title)
        gtk_box_append(ptr(lines), host)

        gtk_box_append(ptr(card), iconSlot)
        gtk_box_append(ptr(card), lines)

        let address = URL(string: url)
        let first = source.cachedFace(url) ?? address.map(LinkCardFace.placeholder(for:))
            ?? .placeholder(host: url, path: url)
        apply(first, title: title, host: host)

        let cardRef = WidgetRef(card)
        let titleRef = WidgetRef(title)
        let hostRef = WidgetRef(host)
        let slotRef = WidgetRef(iconSlot)
        wireActions(card: card, ref: cardRef, url: url, context: context)

        guard let address else {
            return Parts(card: card, title: title, host: host, iconSlot: iconSlot, task: nil)
        }
        let known = source.cachedFace(url) != nil
        let task = Task {
            if !known {
                let wanted = await LinkEmbedPolicy.settle(debounce: source.debounce) {
                    cardRef.isAlive
                }
                guard wanted else { return }
                let metadata = await source.metadata(url)
                let face = LinkCardFace.settled(for: address, metadata: metadata)
                Gtk.onMain {
                    titleRef.with { title in
                        hostRef.with { host in apply(face, title: title, host: host) }
                    }
                }
            }
            await paintIcon(for: url, source: source, slot: slotRef)
        }
        Gtk.connect(UnsafeMutableRawPointer(card), "destroy") { task.cancel() }
        return Parts(card: card, title: title, host: host, iconSlot: iconSlot, task: task)
    }

    /// The two lines. The headline wears the quieter ink while it is only the host standing in for
    /// a title, so a card that never learned its page's name does not look like one that did.
    static func apply(
        _ face: LinkCardFace, title: UnsafeMutablePointer<GtkWidget>,
        host: UnsafeMutablePointer<GtkWidget>
    ) {
        gtk_label_set_text(op(title), face.headline)
        gtk_label_set_text(op(host), face.caption)
        if face.headlineIsQuiet {
            gtk_widget_add_css_class(title, "link-card-title-quiet")
        } else {
            gtk_widget_remove_css_class(title, "link-card-title-quiet")
        }
    }

    private static func glyph() -> UnsafeMutablePointer<GtkWidget> {
        let mark = Gtk.label("⊕", css: "link-card-glyph", selectable: false)
        gtk_widget_set_halign(mark, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(mark, GTK_ALIGN_CENTER)
        gtk_widget_set_hexpand(mark, 1)
        gtk_widget_set_vexpand(mark, 1)
        return mark
    }

    /// The page's own icon, once it is known and decodable, in place of the glyph. Decoding stays
    /// off the GLib main context; the picture is made where GTK lives, in the same hop that reads
    /// or fills the shared texture cache, so an eviction cannot land between the two. A page with
    /// no icon, or one the loader cannot read, simply keeps its glyph.
    private static func paintIcon(for url: String, source: LinkCardSource, slot: WidgetRef) async {
        let cached = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            Gtk.onMain {
                let bits = MediaImageCache.shared.texture(for: url)
                if bits != 0 { slot.with { place(bits, in: $0) } }
                continuation.resume(returning: bits != 0)
            }
        }
        guard !cached, slot.isAlive else { return }
        guard let data = await source.favicon(url), !Task.isCancelled else { return }
        let bits = MediaImageCache.decode(data)
        guard bits != 0 else { return }
        Gtk.onMain {
            MediaImageCache.shared.store(bits, for: url)
            slot.with { place(bits, in: $0) }
        }
    }

    private static func place(_ bits: UInt, in slot: UnsafeMutablePointer<GtkWidget>) {
        guard let picture = MediaImageCache.shared.picture(bits, width: iconSize, height: iconSize)
        else { return }
        gtk_picture_set_content_fit(op(picture), GTK_CONTENT_FIT_CONTAIN)
        Gtk.removeChildren(of: slot)
        gtk_box_append(ptr(slot), picture)
        gtk_widget_add_css_class(slot, "link-card-icon-loaded")
    }

    /// A press opens the address in the reader's own browser, the way a link in the prose does;
    /// right-click offers the two things a link can be asked for.
    private static func wireActions(
        card: UnsafeMutablePointer<GtkWidget>, ref: WidgetRef, url: String,
        context: TranscriptContext?
    ) {
        Gtk.onPrimaryRelease(card) {
            ref.with { tailscode_open_uri($0, url) }
        }
        let toast = context?.toast
        Gtk.onRightClick(card) { x, y in
            ref.with { card in
                Gtk.contextMenu(
                    on: card, x: x, y: y, rows: menuRows(url: url, ref: ref, toast: toast))
            }
        }
    }

    /// What a link can be asked for: opened where a press would open it, or its address copied.
    static func menuRows(
        url: String, ref: WidgetRef, toast: (@Sendable (String) -> Void)?
    ) -> [(title: String, detail: String?, action: @Sendable () -> Void)] {
        [
            (title: Localized.text("Open Link"), detail: nil,
                action: { ref.with { tailscode_open_uri($0, url) } }),
            (title: Localized.text("Copy link"), detail: nil,
                action: {
                    Gtk.copyToClipboard(url)
                    toast?(Localized.text("Link copied."))
                }),
        ]
    }
}
