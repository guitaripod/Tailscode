import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension BrainAccount {
    func wheel(_ dy: Double) -> Bool {
        let place = ScrollHandoff.Metrics(offset: target, content: total, viewport: viewHeight)
        guard ScrollHandoff.notch(-dy, in: place) == .inner else { return false }
        holdAnchor = nil
        let next = min(max(target + dy * Self.wheelStep, 0), maxScroll)
        guard next != target else { return true }
        pendingReveal = nil
        target = next
        if BrainBudget.reduceMotion { scroll = target }
        owner.browse(.scrolled(manual: true), grabFocus: false)
        owner.listAnimationChanged()
        tailscode_brain_row_invalidate(story)
        return true
    }

    func driveScroll(_ pixels: Double) {
        target = min(max(target + pixels, 0), maxScroll)
        pendingReveal = nil
        if BrainBudget.reduceMotion { scroll = target }
        owner.browse(.scrolled(manual: true), grabFocus: false)
        owner.listAnimationChanged()
        tailscode_brain_row_invalidate(story)
    }

    func scrollToEnd(jump: Bool = false) {
        pendingReveal = nil
        target = maxScroll
        if jump || BrainBudget.reduceMotion { scroll = target }
        owner.listAnimationChanged()
        tailscode_brain_row_invalidate(story)
    }

    func scrollToStart() {
        pendingReveal = nil
        target = 0
        if BrainBudget.reduceMotion { scroll = 0 }
        owner.listAnimationChanged()
        tailscode_brain_row_invalidate(story)
    }

    var isAnimating: Bool {
        if abs(scroll - target) > 0.4 { return true }
        let now = BrainClock.now
        if arrivals.values.contains(where: { now - $0 < Self.arrivalDuration }) { return true }
        return justNow.values.contains { now - $0 < Self.justNowDuration + 0.05 }
    }

    func tick(_ time: Double) {
        guard !disposed else { return }
        let dt = lastTick == 0 ? 1.0 / 60 : min(0.1, time - lastTick)
        lastTick = time
        var changed = false
        if abs(scroll - target) > 0.4 {
            let before = scroll
            scroll += (target - scroll) * (1 - exp(-dt / Self.scrollEase))
            if abs(scroll - target) <= 0.4 {
                scroll = target
                pendingReveal = nil
            }
            changed = changed || before != scroll
        } else if scroll != target {
            scroll = target
            pendingReveal = nil
            changed = true
        }
        let expired = arrivals.filter { time - $0.value >= Self.arrivalDuration }.map(\.key)
        for id in expired {
            arrivals[id] = nil
            changed = true
        }
        let old = justNow.filter { time - $0.value >= Self.justNowDuration }.map(\.key)
        for id in old {
            justNow[id] = nil
            cells[id]?.hideJustNow()
        }
        if changed || !arrivals.isEmpty {
            tailscode_brain_row_invalidate(story)
            gtk_widget_queue_draw(scrollbar)
            if abs(scroll - target) < 0.5 || changed { scheduleRealizeIfNeeded() }
        }
        if lastTick != 0, !isAnimating { lastTick = 0 }
    }

    func scheduleRealizeIfNeeded() {
        if needsRealizeNow() { scheduleRealize() }
    }

    /// What the harness reads: how many items exist, how long the story is, where it is scrolled.
    var reading: String {
        let held = cells.keys.compactMap { entryIndex[$0] }.sorted()
        let range = held.isEmpty ? "-" : "\(held.first!)...\(held.last!)"
        let widgets = cells.values.reduce(0) { $0 + $1.widgetCount }
        return String(
            format: "items=%d realized=%d range=%@ widgets=%d total=%.0f scroll=%.0f/%.0f view=%.0f box=%.0f solves=%d mean=%.0fus worst=%.0fus refreshes=%d refresh=%.0fus realizes=%d realize=%.0fms",
            entries.count, cells.count, range, widgets, total, scroll, target, viewHeight, boxWidth, solves,
            solves == 0 ? 0 : Double(solveNanoseconds) / Double(solves) / 1000, Double(worstSolve) / 1000,
            refreshes, refreshes == 0 ? 0 : Double(refreshNanoseconds) / Double(refreshes) / 1000, realizeCount,
            Double(realizeNanoseconds) / 1_000_000)
    }

    var widgetCount: Int {
        func count(_ node: UnsafeMutablePointer<GtkWidget>) -> Int {
            var total = 1
            var child = gtk_widget_get_first_child(node)
            while let held = child {
                total += count(held)
                child = gtk_widget_get_next_sibling(held)
            }
            return total
        }
        return count(root)
    }

    /// The text of every label of the items that exist, in story order, for the harness to read
    /// what the account says.
    var visibleText: String {
        var words: [String] = []
        func walk(_ widget: UnsafeMutablePointer<GtkWidget>) {
            let instance = UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GTypeInstance.self)
            if g_type_check_instance_is_a(instance, gtk_label_get_type()) != 0,
                let raw = gtk_label_get_text(op(widget))
            {
                words.append(String(cString: raw))
            }
            var child = gtk_widget_get_first_child(widget)
            while let held = child {
                walk(held)
                child = gtk_widget_get_next_sibling(held)
            }
        }
        walk(header)
        for pin in [askPin, nowPin, planPin].compactMap({ $0 }) { walk(pin.widget) }
        for entry in entries { if let cell = cells[entry.id] { walk(cell.widget) } }
        return words.joined(separator: "\n")
    }

    /// Every widget of the items that exist whose own minimum width is wider than the box they
    /// are laid out in, which the toolkit complains of: for the harness.
    func overflowReading() -> String {
        var lines: [String] = []
        func walk(_ node: UnsafeMutablePointer<GtkWidget>, depth: Int, id: String) {
            if gtk_widget_get_visible(node) == 0 { return }
            var minimum: Int32 = 0
            var natural: Int32 = 0
            gtk_widget_measure(node, GTK_ORIENTATION_HORIZONTAL, -1, &minimum, &natural, nil, nil)
            if Double(minimum) > boxWidth + 0.5 {
                var classes = ""
                if let list = gtk_widget_get_css_classes(node) {
                    var index = 0
                    while let item = list[index] {
                        classes += String(cString: item) + "."
                        index += 1
                    }
                    g_strfreev(list)
                }
                lines.append("\(id) \(String(repeating: " ", count: depth))\(String(cString: gtk_widget_get_css_name(node))).\(classes) min=\(minimum) nat=\(natural)")
            }
            var child = gtk_widget_get_first_child(node)
            while let held = child {
                walk(held, depth: depth + 1, id: id)
                child = gtk_widget_get_next_sibling(held)
            }
        }
        for entry in entries { if let cell = cells[entry.id] { walk(cell.widget, depth: 0, id: entry.id) } }
        for (name, pin) in [("ask", askPin), ("now", nowPin), ("plan", planPin)] { if let pin { walk(pin.widget, depth: 0, id: name) } }
        return lines.joined(separator: " ; ")
    }

    func resetSolveStats() {
        solveNanoseconds = 0
        worstSolve = 0
        solves = 0
    }
}
