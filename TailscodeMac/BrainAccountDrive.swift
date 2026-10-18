#if DEBUG
    import AppKit
    import TailscodeCore

    /// `TAILSCODE_DRIVE="2000:brain=acct=unfold:1"` — the account's own verbs, on the open brain.
    ///
    /// - `top`, `end`, `scroll:<points>` move the story at once
    /// - `unfold:<n>`, `fold:<n>` open and close the n-th work line (counting work lines only)
    /// - `show:<n>` unfolds the n-th note's words, `think:<n>` the n-th thought's
    /// - `expand` folds or unfolds the long output of the open card
    /// - `plan` folds or unfolds the plan, `focus` takes the keyboard into the account
    /// - `reading` prints what the account holds
    @MainActor
    enum BrainAccountDrive {
        static func perform(_ argument: String) -> String {
            let pieces = argument.split(separator: ":", maxSplits: 1).map(String.init)
            if pieces.first == "shot" { return dumpShot(pieces.count > 1 ? pieces[1] : "") }
            guard let row = BrainRowView.live.first(where: { $0.isOpenShown && $0.window != nil }),
                let account = row.account
            else { return "BRAIN acct no open account" }
            let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
            let verb = parts.first ?? ""
            let number = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
            switch verb {
            case "top": account.scrollToStart()
            case "end": account.scrollToEnd(jump: true)
            case "scroll": account.scrollTo(CGFloat(number), animated: false)
            case "unfold": setWork(account, number, open: true)
            case "fold": setWork(account, number, open: false)
            case "show": toggleText(account, number, said: true)
            case "think": toggleText(account, number, said: false)
            case "expand": _ = account.toggleCardOutput()
            case "plan": account.togglePlan(nil)
            case "focus": account.focus()
            case "reading": break
            default: return "BRAIN acct unknown verb \(verb)"
            }
            account.refresh(immediate: true)
            account.realize()
            return "BRAIN acct " + account.reading
        }

        /// `shot:<path>:<width>:<step>:<turn>` — a fixture of the demo conversation at `width`, the
        /// brain of that turn open with the cursor on that step (0 for none), the account drawn to a
        /// PNG whatever the screen's size, so a layout the display cannot hold can be looked at.
        private static func dumpShot(_ spec: String) -> String {
            let parts = spec.split(separator: ":").map(String.init)
            guard parts.count >= 4, let width = Double(parts[1]), let step = Int(parts[2]), let turn = Int(parts[3]) else {
                return "BRAIN acct shot needs path:width:step:turn"
            }
            let was = DisplayGate.assumesVisible
            DisplayGate.assumesVisible = true
            defer { DisplayGate.assumesVisible = was }
            let fixture = BrainFixture(width: CGFloat(width))
            fixture.window.appearance = NSApp.effectiveAppearance
            defer { for view in fixture.views.values { view.removeFromSuperview() } }
            guard let row = fixture.open(turn), let account = row.account else { return "BRAIN acct shot could not open" }
            func settle() {
                row.superview?.layoutSubtreeIfNeeded()
                account.refresh(immediate: true)
                account.layoutSubtreeIfNeeded()
                account.holdAnchor = nil
                for _ in 0..<4 {
                    account.realize()
                    account.settleReveal()
                }
                account.pendingReveal = nil
                account.layoutSubtreeIfNeeded()
            }
            settle()
            if step > 0, row.model.steps.indices.contains(step - 1) {
                account.choose(row.model.steps[step - 1].id, fromAccount: false)
                settle()
            }
            let rect = account.convert(account.bounds, to: fixture.root)
            let back = AccountRuleView(frame: rect)
            back.color = AccountPaint(row.inks).canvas
            fixture.root.addSubview(back, positioned: .below, relativeTo: nil)
            guard let rep = fixture.root.bitmapImageRepForCachingDisplay(in: rect) else { return "BRAIN acct shot no bitmap" }
            fixture.root.cacheDisplay(in: rect, to: rep)
            back.removeFromSuperview()
            let flat = NSImage(size: rect.size)
            flat.lockFocus()
            rep.draw(in: NSRect(origin: .zero, size: rect.size))
            flat.unlockFocus()
            guard let tiff = flat.tiffRepresentation, let out = NSBitmapImageRep(data: tiff),
                let png = out.representation(using: .png, properties: [:])
            else { return "BRAIN acct shot no png" }
            try? png.write(to: URL(fileURLWithPath: parts[0]))
            return "BRAIN acct shot \(parts[0]) \(Int(rect.width))x\(Int(rect.height)) twoColumns=\(account.isTwoColumns) \(account.reading)"
        }

        private static func setWork(_ account: BrainAccountView, _ number: Int, open: Bool) {
            let works = account.entries.filter(\.isWork)
            guard works.indices.contains(number - 1) else { return }
            let id = works[number - 1].id
            if open { account.unfolded.insert(id) } else { account.unfolded.remove(id) }
        }

        private static func toggleText(_ account: BrainAccountView, _ number: Int, said: Bool) {
            let items = account.entries.filter {
                switch $0.kind {
                case .said: return said
                case .thought: return !said
                default: return false
                }
            }
            guard items.indices.contains(number - 1) else { return }
            account.toggleText(items[number - 1].id)
        }
    }
#endif
