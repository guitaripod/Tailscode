import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension BrainView {
    /// The drive verbs of the account: `account` (says what it holds), `reply=<n>` and `copy=<n>`
    /// (a note's two buttons), `said=next|prev`, `ask`, `follow` (the pill), `unfold=<n>` (the work
    /// line that holds step n), `acctscroll=<px>`, `acctfocus`, and `acctkey=<key>` (a key as the
    /// account hears it). Numbers are one-based steps.
    func driveAccount(verb: String, value: String) {
        func id(_ text: String) -> String? {
            guard let number = Int(text), number >= 1, number <= model.steps.count else { return nil }
            return model.steps[number - 1].id
        }
        switch verb {
        case "reply":
            if let step = id(value) { accountReply(step) }
        case "copy":
            if let step = id(value) { accountCopy(step) }
        case "said":
            browse(.key(.character(value == "prev" ? "S" : "s")), grabFocus: false)
        case "ask":
            browse(.key(.character("a")), grabFocus: false)
        case "follow":
            accountJumpToLatest()
        case "unfold":
            if let step = id(value), let item = account?.account.item(containing: step) { accountToggleWork(item.id) }
        case "acctscroll":
            account?.driveScroll(Double(value) ?? 0)
        case "acctfocus":
            account?.focus()
        case "acctkey":
            driveAccountKey(value)
        case "acctbench":
            driveAccountBench(seconds: Double(value) ?? 4)
        default:
            break
        }
    }

    /// Scrolls the account a fixed step on every frame for a few seconds, back and forth over its
    /// whole length, and says how long the frames took and how many widgets it held at most.
    private func driveAccountBench(seconds: Double) {
        guard let account, let window = gtk_widget_get_root(widget) else { return }
        let bench = AccountBench(account: account, seconds: seconds)
        let box = Unmanaged.passRetained(bench).toOpaque()
        _ = Gtk.releaseInstalled
        _ = tailscode_add_owned_tick(
            ptr(UnsafeMutableRawPointer(window)),
            { raw in
                guard let raw else { return 0 }
                return Unmanaged<AccountBench>.fromOpaque(raw).takeUnretainedValue().tick() ? 1 : 0
            }, box)
    }

    private final class AccountBench: @unchecked Sendable {
        let account: BrainAccount
        let seconds: Double
        var start = 0.0
        var last = 0.0
        var gaps: [Double] = []
        var direction = 1.0
        var widgets = 0
        var most = 0

        init(account: BrainAccount, seconds: Double) {
            self.account = account
            self.seconds = seconds
        }

        func tick() -> Bool {
            let now = BrainClock.now
            if start == 0 {
                start = now
                account.resetSolveStats()
            }
            if last != 0 { gaps.append(now - last) }
            last = now
            if account.scroll >= account.maxScroll - 1 { direction = -1 }
            if account.scroll <= 1 { direction = 1 }
            account.driveScroll(direction * 64)
            most = max(most, account.cells.values.reduce(0) { $0 + $1.widgetCount })
            if now - start < seconds { return true }
            let sorted = gaps.sorted()
            func at(_ fraction: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))] }
            let line = String(
                format: "BRAIN acctbench frames=%d median=%.1fms p95=%.1fms p99=%.1fms max=%.1fms over25ms=%d widgetsMax=%d items=%d %@\n",
                gaps.count + 1, at(0.5) * 1000, at(0.95) * 1000, at(0.99) * 1000, (sorted.last ?? 0) * 1000,
                gaps.filter { $0 > 0.025 }.count, most, account.entries.count, account.reading)
            FileHandle.standardOutput.write(Data(line.utf8))
            return false
        }
    }

    private func driveAccountKey(_ name: String) {
        let table: [String: Int32] = [
            "up": GDK_KEY_Up, "down": GDK_KEY_Down, "home": GDK_KEY_Home, "end": GDK_KEY_End,
            "enter": GDK_KEY_Return, "space": GDK_KEY_space, "esc": GDK_KEY_Escape,
            "pgup": GDK_KEY_Page_Up, "pgdn": GDK_KEY_Page_Down,
        ]
        if let code = table[name] {
            _ = accountKey(keyval: UInt32(code), state: 0)
            return
        }
        guard let scalar = name.unicodeScalars.first, name.count == 1 else { return }
        let shift: UInt32 = scalar.properties.isUppercase ? GDK_SHIFT_MASK.rawValue : 0
        _ = accountKey(keyval: gdk_unicode_to_keyval(scalar.value), state: shift)
    }
}
