import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension ChatPane {
    /// Takes the transcript to the first row a message drew, when that message is still among the
    /// rows on screen.
    func scrollToMessage(_ messageID: String) {
        let prefix = messageID + ":"
        guard let index = renderedRows.firstIndex(where: { $0.key.hasPrefix(prefix) }) else {
            return
        }
        scrollToRow(at: index)
    }

    /// The card for one named agent — matched to the tool call that spawned it — and its
    /// transcript opened on arrival.
    func scrollToAgent(_ id: String) {
        for (index, row) in renderedRows.enumerated() {
            switch row.kind {
            case .subagent(let call) where call.id == id:
                context.expanded.set(row.key, open: true)
                replaceRows { $0.key == row.key }
                fetchSubagent(call)
                scrollToRow(at: index)
                return
            case .subagentGroup(let members):
                guard let member = members.first(where: { $0.call.id == id }) else { continue }
                context.expanded.set(row.key, open: true)
                context.expanded.set(member.key, open: true)
                replaceRows { $0.key == row.key }
                fetchSubagent(member.call)
                scrollToRow(at: index)
                return
            default:
                continue
            }
        }
        scrollToNewestAgent()
    }

    func scrollToRow(at index: Int) {
        guard index < rowWidgets.count,
            let raw = UnsafeMutableRawPointer(bitPattern: rowWidgets[index])
        else { return }
        let widget: UnsafeMutablePointer<GtkWidget> = ptr(raw)
        let offset = tailscode_widget_offset_y(widget, canvasBox ?? transcriptBox)
        guard offset >= 0, let scroller = transcriptScroller,
            let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller))
        else { return }
        followsBottom = false
        let page = gtk_adjustment_get_page_size(adjustment)
        gtk_adjustment_set_value(
            adjustment,
            min(max(0, offset - page * 0.3), max(0, gtk_adjustment_get_upper(adjustment) - page)))
    }

    func scrollToNewestAgent() {
        for (index, row) in renderedRows.enumerated().reversed() {
            switch row.kind {
            case .subagent, .subagentGroup: break
            default: continue
            }
            guard index < rowWidgets.count,
                let raw = UnsafeMutableRawPointer(bitPattern: rowWidgets[index])
            else { continue }
            let widget: UnsafeMutablePointer<GtkWidget> = ptr(raw)
            let offset = tailscode_widget_offset_y(widget, canvasBox ?? transcriptBox)
            guard offset >= 0, let scroller = transcriptScroller,
                let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller))
            else { return }
            let page = gtk_adjustment_get_page_size(adjustment)
            gtk_adjustment_set_value(
                adjustment,
                min(max(0, offset - page * 0.3), max(0, gtk_adjustment_get_upper(adjustment) - page)))
            return
        }
        scroll(toEnd: true)
    }

    static let firstFillFloor = 12

    static let firstFillCeiling = 32

    static let firstFillFallback = 24

    static let typicalRowHeight = 80.0

    static let coveredShare = 1.05

    static let runway = 1.5

    /// Rows the first apply of a chat puts on the page: about what a screen of the usual row
    /// holds. The frame that draws them lays every one out, and a frame that takes a quarter of a
    /// second is what the governor reads as load and answers by slowing everything for the better
    /// part of a minute; the hops that follow are not held back while the page is still short.
    func firstFillRows() -> Int {
        guard let page = pageHeight, page > 0 else { return Self.firstFillFallback }
        let usual = Int(page / Self.typicalRowHeight)
        let rows = min(Self.firstFillCeiling, max(Self.firstFillFloor, usual))
        return CascadeBudget.level >= .loaded ? max(8, rows / 2) : rows
    }

    var pageHeight: Double? {
        guard let scroller = transcriptScroller,
            let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller))
        else { return nil }
        return gtk_adjustment_get_page_size(adjustment)
    }

    /// Whether what has been drawn reaches past one screen, which is when a chat that was kept
    /// hidden while it was put together can be shown: the end of the conversation is on screen and
    /// there is more above it.
    var pageIsCovered: Bool {
        guard let scroller = transcriptScroller,
            let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller))
        else { return false }
        let page = gtk_adjustment_get_page_size(adjustment)
        return page > 0 && gtk_adjustment_get_upper(adjustment) >= page * Self.coveredShare
    }

    /// Whether the backfill has someone waiting on it: a page not yet covered, which is hidden
    /// until it is, or a reader within a screen and a half of the first row that exists.
    var pageNeedsRows: Bool {
        guard !fillComplete, let scroller = transcriptScroller,
            let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller))
        else { return false }
        let page = gtk_adjustment_get_page_size(adjustment)
        guard page > 0 else { return true }
        if pendingReveal { return !pageIsCovered }
        return gtk_adjustment_get_value(adjustment) < page * Self.runway
    }

    /// A chat that was hidden while its first screens were put together is shown the moment they
    /// cover the page, or when the whole of it is there; the rest of the history goes on arriving
    /// above the reader without moving a row.
    var readyToReveal: Bool {
        fillComplete || (followsBottom && canvasPromptKey == nil && pageIsCovered)
    }

    /// Runs `add`, which puts rows above everything the page shows, and writes the height they
    /// brought into the scroll position in the same breath. A scrolled window holds an offset, so
    /// rows added above it push what the reader is looking at down by their height until something
    /// puts the offset back — and the something used to be an idle after the frame, which is a frame
    /// of the wrong place per hop. The height is the transcript's own, asked before and after at
    /// the width it has: rows already measured answer from the toolkit's cache, and the new ones
    /// are measured here instead of in the frame that would have measured them anyway.
    func holdingThePlace(_ add: () -> Void) {
        let width = gtk_widget_get_width(transcriptBox)
        guard !pendingReveal, width > 0, let scroller = transcriptScroller,
            let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller))
        else {
            add()
            return
        }
        let before = naturalHeight(of: transcriptBox, at: width)
        add()
        let delta = naturalHeight(of: transcriptBox, at: width) - before
        guard delta > 0.5 else { return }
        isAutoScrolling = true
        gtk_adjustment_configure(
            adjustment, gtk_adjustment_get_value(adjustment) + delta,
            gtk_adjustment_get_lower(adjustment), gtk_adjustment_get_upper(adjustment) + delta,
            gtk_adjustment_get_step_increment(adjustment),
            gtk_adjustment_get_page_increment(adjustment), gtk_adjustment_get_page_size(adjustment))
        isAutoScrolling = false
    }

    func naturalHeight(of widget: UnsafeMutablePointer<GtkWidget>, at width: Int32) -> Double {
        var minimum: Int32 = 0
        var natural: Int32 = 0
        gtk_widget_measure(widget, GTK_ORIENTATION_VERTICAL, width, &minimum, &natural, nil, nil)
        return Double(natural)
    }

    /// Runs outside layout, after the current pass has settled: pins, then queues an allocation
    /// on the viewport, so the pixels always match the adjustment. Also the moment a
    /// freshly-filled transcript is revealed.
    func schedulePinCorrector() {
        guard !pinCorrectorScheduled else { return }
        pinCorrectorScheduled = true
        Gtk.onMain { [weak self] in
            guard let self else { return }
            self.pinCorrectorScheduled = false
            if self.followsBottom { self.pinToBottom() }
            if let scroller = self.transcriptScroller {
                gtk_widget_queue_allocate(scroller)
                if let viewport = gtk_widget_get_first_child(scroller) {
                    gtk_widget_queue_allocate(viewport)
                }
            }
            if self.pendingReveal, self.readyToReveal {
                self.pendingReveal = false
                gtk_widget_set_opacity(self.transcriptBox, 1)
                self.openTimer.note("revealed")
            }
        }
    }

    /// The rendered rows with their widgets, in order, for the scroll anchor to find a row by key.
    func anchorRows() -> [ScrollAnchor.Row] {
        guard renderedRows.count == rowWidgets.count else { return [] }
        return zip(renderedRows, rowWidgets).map { ($0.key, $1) }
    }

    /// A reader who scrolls up toward the first row that exists is waiting on the backfill, so the
    /// moment the runway under them is short the queue stops resting. Asked once per approach.
    func askForRowsAtTheEdge() {
        let short = pageNeedsRows
        guard short != rushing else { return }
        rushing = short
        if short { FillTurns.rush() }
    }

    func placeAnchored(_ value: Double) {
        guard let scroller = transcriptScroller,
            let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller))
        else { return }
        isAutoScrolling = true
        gtk_adjustment_set_value(adjustment, value)
        isAutoScrolling = false
    }

    /// A brain above the reader's place is about to open or close: the row at the top of the
    /// viewport is held where it is while the heights settle, unless the transcript is following
    /// its end (where the pin keeps the end in view) or a fresh canvas is holding a prompt.
    func holdScrollAnchor() {
        guard !followsBottom, canvasPromptKey == nil, fillComplete else { return }
        scrollAnchor?.capture()
    }

    /// Whether a brain's row is within a screenful of the reader's place, which decides whether
    /// the brain keeps a clock and builds the words of its card.
    func brainOnScreen(_ view: BrainView) -> Bool {
        guard let canvas = canvasBox, let scroller = transcriptScroller,
            let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller)),
            let box = Gtk.bounds(of: view.widget, in: canvas)
        else { return true }
        let page = gtk_adjustment_get_page_size(adjustment)
        guard page > 0 else { return true }
        let top = gtk_adjustment_get_value(adjustment)
        return box.y + box.height > top - 120 && box.y < top + page + 120
    }

    /// The row the scroll anchor is holding, for the harness.
    var heldAnchorKey: String? { scrollAnchor?.holdsKey }

    /// The gentlest scroll that shows a just-opened body: down only as far as the body's end (or
    /// the page can hold), and never past the point where the clicked header would leave the top —
    /// a header that flies off the screen is the person losing the very thing they pointed at.
    /// Runs on the idle after the open, once the body has its allocation; a row already rebuilt or
    /// torn off screen by then simply fails the bounds check and moves nothing.
    func revealDisclosure(_ bits: UInt) {
        guard let raw = UnsafeMutableRawPointer(bitPattern: bits),
            let canvas = canvasBox, let scroller = transcriptScroller,
            let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller))
        else { return }
        var x = 0.0
        var y = 0.0
        var width = 0.0
        var height = 0.0
        guard tailscode_widget_bounds_in(ptr(raw), canvas, &x, &y, &width, &height) != 0,
            height > 0
        else { return }
        let value = gtk_adjustment_get_value(adjustment)
        let page = gtk_adjustment_get_page_size(adjustment)
        guard page > 0 else { return }
        let margin = 8.0
        let needed = y + height + margin - (value + page)
        let slack = y - margin - value
        let delta = min(needed, slack)
        guard delta > 0 else { return }
        let ceiling = max(0, gtk_adjustment_get_upper(adjustment) - page)
        isAutoScrolling = true
        gtk_adjustment_set_value(adjustment, min(value + delta, ceiling))
        isAutoScrolling = false
    }

    func scroll(by amount: Double) {
        adjust { $0 + amount }
    }

    /// The transcript's whole content height — the scrolled window's adjustment upper bound — with
    /// the pane's width and what is drawn, the figure the compact-chat measure is taken from.
    var contentHeightSummary: String {
        guard let scroller = transcriptScroller,
            let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller))
        else { return "none" }
        var natural: Int32 = 0
        if let canvas = canvasBox {
            gtk_widget_measure(
                canvas, GTK_ORIENTATION_VERTICAL, gtk_widget_get_width(canvas), &natural, nil, nil,
                nil)
        }
        return String(
            format: "content=%d upper=%.0f page=%.0f width=%d rows=%d widgets=%d", natural,
            gtk_adjustment_get_upper(adjustment), gtk_adjustment_get_page_size(adjustment),
            gtk_widget_get_width(scroller), renderedRows.count, rowWidgets.count)
    }

    func scroll(byPages fraction: Double) {
        guard let scroller = transcriptScroller,
            let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller))
        else { return }
        let page = gtk_adjustment_get_page_size(adjustment) * fraction
        adjust { $0 + page }
    }

    func scroll(toEnd bottom: Bool) {
        guard let scroller = transcriptScroller,
            let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller))
        else { return }
        let limit =
            bottom
            ? gtk_adjustment_get_upper(adjustment) - gtk_adjustment_get_page_size(adjustment)
            : gtk_adjustment_get_lower(adjustment)
        adjust { _ in limit }
    }

    /// The previous or next thing the person said, put at the top of the window: the transcript
    /// read as a list of questions. It stops at the first and the last rather than wrapping, and
    /// a window with nothing the person said in it does nothing.
    func jumpPrompt(by direction: Int) {
        guard let scroller = transcriptScroller, let canvas = canvasBox,
            let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller))
        else { return }
        let headroom = 8.0
        var tops: [Double] = []
        for (index, row) in renderedRows.enumerated() where index < rowWidgets.count {
            switch row.kind {
            case .userText, .pendingSend: break
            default: continue
            }
            guard let raw = UnsafeMutableRawPointer(bitPattern: rowWidgets[index]) else { continue }
            let offset = tailscode_widget_offset_y(ptr(raw), canvas)
            if offset >= 0 { tops.append(max(0, offset - headroom)) }
        }
        guard !tops.isEmpty else { return }
        let value = gtk_adjustment_get_value(adjustment)
        let target =
            direction < 0
            ? (tops.last { $0 < value - 1 } ?? tops[0])
            : (tops.first { $0 > value + 1 } ?? tops[tops.count - 1])
        let ceiling = max(0, gtk_adjustment_get_upper(adjustment) - gtk_adjustment_get_page_size(adjustment))
        followsBottom = false
        gtk_adjustment_set_value(adjustment, min(target, ceiling))
    }

    /// The words of the newest answer, on the pasteboard, said in the same breath: what the hover
    /// bar's Copy does for the message the pointer is over, from the keyboard.
    @discardableResult
    func copyLastAnswer() -> Bool {
        guard
            let message = lastState?.messages.last(where: {
                $0.role == .assistant
                    && !AgentMarkup.strip($0.text).trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
            })
        else { return false }
        let words = AgentMarkup.strip(message.text).trimmingCharacters(in: .whitespacesAndNewlines)
        Gtk.copyToClipboard(words)
        host?.toast(Localized.text("Copied the last answer"))
        return true
    }

    /// Esc from the composer leaves the prompt box for this pane's own transcript — the keyboard
    /// stays in the conversation it was in, with the scrolling keys live, instead of jumping to the
    /// chat list across the window.
    func leaveComposer() {
        guard let scroller = transcriptScroller else { return }
        gtk_widget_set_focusable(scroller, 1)
        gtk_widget_grab_focus(scroller)
    }

    func adjust(_ transform: (Double) -> Double) {
        guard let scroller = transcriptScroller,
            let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller))
        else { return }
        let ceiling = gtk_adjustment_get_upper(adjustment)
            - gtk_adjustment_get_page_size(adjustment)
        let next = min(max(gtk_adjustment_get_lower(adjustment),
            transform(gtk_adjustment_get_value(adjustment))), max(0, ceiling))
        gtk_adjustment_set_value(adjustment, next)
    }
}
