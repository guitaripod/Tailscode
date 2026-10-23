import AppKit
import os
import CodingAgentKit
import TailscodeCore

extension TranscriptViewController {
    /// The message under a point on the page and every row it is drawn as: a prompt with the
    /// pictures that went with it, or an answer's words, code and tables. Rows that are the agent
    /// working — a thought, a tool call, a card — have headers of their own and no capsule.
    func messageTarget(at point: NSPoint) -> MessageHoverBar.Target? {
        guard !placeholderShown, let index = rowIndex(atCanvasY: point.y),
            let owner = messageOwner(of: renderedRows[index])
        else { return nil }
        var first = index
        while first > 0, messageOwner(of: renderedRows[first - 1])?.id == owner.id { first -= 1 }
        var last = index
        while last + 1 < min(renderedRows.count, rowViews.count),
            messageOwner(of: renderedRows[last + 1])?.id == owner.id
        {
            last += 1
        }
        var block: NSRect?
        for row in first...last where rowViews[row].superview != nil {
            let frame = rowViews[row].convert(rowViews[row].bounds, to: canvas)
            block = block.map { $0.union(frame) } ?? frame
        }
        guard let block else { return nil }
        return MessageHoverBar.Target(messageID: owner.id, isPrompt: owner.prompt, block: block)
    }

    /// Which message a row draws, when it draws one's words. An answer's rows are keyed by the
    /// message and the part they came from, so the message is the one whose id leads the key.
    private func messageOwner(of row: TranscriptRow) -> (id: String, prompt: Bool)? {
        switch row.kind {
        case .userText(_, let messageID): return (messageID, true)
        case .file(_, let mine, let messageID): return mine ? (messageID, true) : nil
        case .agentProse, .codeBlock, .table, .tableDraft:
            guard let message = lastState?.messages.last(where: { row.key.hasPrefix($0.id + ":") })
            else { return nil }
            return (message.id, false)
        default: return nil
        }
    }

    /// The row standing at a height on the page, found by halving: the rows stand top-down in the
    /// order they are kept, so a pointer's row is a search rather than a walk.
    #if DEBUG
        /// `--open stage:<messages.json>[,rail=down|up][,code][,scroll=top|bottom|<row>]` — shows a
        /// transcript from a file of messages in the cached shape, in place of whatever the pane
        /// holds, so a layout, a rail or a code block can be looked at without a server that would
        /// write the right conversation. A rail is opened as a press would, on the first rail on
        /// the page, with the page scrolled so the plate has the room the directive names.
        func stage(messagesAt path: String, directives: [String]) {
            guard let data = FileManager.default.contents(atPath: path),
                let messages = try? JSONDecoder().decode([ChatMessage].self, from: data)
            else {
                FileHandle.standardError.write(Data("stage: cannot read messages at \(path)\n".utf8))
                return
            }
            for message in messages {
                for part in message.parts {
                    guard case .file(let reference) = part.kind, let file = reference.path,
                        let image = NSImage(contentsOfFile: file),
                        let rep = image.representations.first
                    else { continue }
                    ImageStore.shared.store(
                        DecodedImage(
                            image: image, data: FileManager.default.contents(atPath: file) ?? Data(),
                            pixelWidth: rep.pixelsWide,
                            pixelHeight: rep.pixelsHigh),
                        forKey: "\(message.id):\(part.id)")
                }
            }
            let state = ConversationState(
                messages: messages, status: .idle, connection: .live, hasLoadedTranscript: true)
            if messages.isEmpty {
                showPlaceholder(ChatSuggestion.headline, starting: true)
                return
            }
            apply(state: state, rows: buildRows(messages, state: state))
            view.layoutSubtreeIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                for directive in directives {
                    let parts = directive.split(separator: "=", maxSplits: 1).map(String.init)
                    switch parts[0] {
                    case "scroll": self?.stageScroll(parts.count > 1 ? parts[1] : "bottom")
                    case "rail": self?.stageRail(opensUpward: parts.count > 1 && parts[1] == "up")
                    case "code": self?.stageCode()
                    case "viewer": self?.stageViewer(parts.count > 1 ? Int(parts[1]) ?? 0 : 0)
                    default: break
                    }
                }
            }
        }

        /// A real click, handed to the application, on the n-th picture the transcript shows, so the
        /// viewer is opened the way a hand opens it. The press lands where the tile is, not on a verb.
        func stageViewer(_ index: Int) {
            view.layoutSubtreeIfNeeded()
            var tiles: [ImageRowView.PictureView] = []
            func collect(_ node: NSView) {
                if let tile = node as? ImageRowView.PictureView { tiles.append(tile) }
                node.subviews.forEach(collect)
            }
            collect(canvas)
            guard tiles.indices.contains(index), let window = view.window else {
                FileHandle.standardError.write(Data("stage: no picture tile \(index)\n".utf8))
                return
            }
            let tile = tiles[index]
            let point = tile.convert(NSPoint(x: tile.bounds.midX, y: tile.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard
                    let event = NSEvent.mouseEvent(
                        with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                else { return }
                NSApp.sendEvent(event)
            }
        }

        private func stageScroll(_ to: String) {
            view.layoutSubtreeIfNeeded()
            let clip = scrollView.contentView
            let range = max(0, canvas.frame.height - clip.bounds.height)
            switch to {
            case "top": clip.scroll(to: NSPoint(x: 0, y: -scrollView.contentInsets.top))
            case "bottom": clip.scroll(to: NSPoint(x: 0, y: range))
            default:
                guard let index = Int(to), index < rowViews.count else { return }
                let frame = rowViews[index].convert(rowViews[index].bounds, to: canvas)
                clip.scroll(to: NSPoint(x: 0, y: min(range, max(0, frame.minY - 80))))
            }
            scrollView.reflectScrolledClipView(clip)
            view.layoutSubtreeIfNeeded()
        }

        private func stageRail(opensUpward: Bool) {
            guard let index = rowViews.firstIndex(where: { $0 is LinkRailLine }),
                let line = rowViews[index] as? LinkRailLine
            else { return }
            let clip = scrollView.contentView
            let range = max(0, canvas.frame.height - clip.bounds.height)
            let frame = line.convert(line.bounds, to: canvas)
            let wanted = opensUpward
                ? frame.maxY - clip.bounds.height + 140 + scrollView.contentInsets.bottom
                : frame.minY - 120
            clip.scroll(to: NSPoint(x: 0, y: min(range, max(0, wanted))))
            scrollView.reflectScrolledClipView(clip)
            view.layoutSubtreeIfNeeded()
            railController.activate(line, viaKeyboard: false)
        }

        private func stageCode() {
            guard let index = renderedRows.firstIndex(where: {
                if case .codeBlock = $0.kind { return true }
                return false
            }), index < rowViews.count else { return }
            let frame = rowViews[index].convert(rowViews[index].bounds, to: canvas)
            let point = NSPoint(x: frame.midX, y: frame.midY)
            guard let target = codeTarget(at: point) else { return }
            hoverBar.stage(code: target)
        }
    #endif

    func codeTarget(at point: NSPoint) -> MessageHoverBar.CodeTarget? {
        guard !placeholderShown, let index = rowIndex(atCanvasY: point.y),
            index < min(rowViews.count, renderedRows.count),
            case .codeBlock(let language, let body) = renderedRows[index].kind,
            rowViews[index].superview != nil
        else { return nil }
        let frame = rowViews[index].convert(rowViews[index].bounds, to: canvas)
        guard frame.contains(point) else { return nil }
        return MessageHoverBar.CodeTarget(
            key: renderedRows[index].key,
            language: SyntaxHighlighter.displayName(for: language, source: body), body: body,
            block: frame)
    }

    func railLine(at point: NSPoint) -> LinkRailLine? {
        guard !placeholderShown, let index = rowIndex(atCanvasY: point.y),
            index < rowViews.count, let line = rowViews[index] as? LinkRailLine
        else { return nil }
        return !line.model.opensDirectly && line.hitRect.contains(line.convert(point, from: canvas))
            ? line : nil
    }

    func railLine(forKey key: String) -> LinkRailLine? {
        guard let index = renderedRows.firstIndex(where: { $0.key == key }),
            index < rowViews.count
        else { return nil }
        return rowViews[index] as? LinkRailLine
    }

    @objc func chatDensityChanged() {
        guard isViewLoaded else { return }
        railController.dismiss()
        rowColumn.metrics = ChatLayout.metrics
        applyUIScale()
    }

    private func rowIndex(atCanvasY y: CGFloat) -> Int? {
        var low = 0
        var high = min(rowViews.count, renderedRows.count) - 1
        while low <= high {
            let middle = (low + high) / 2
            let view = rowViews[middle]
            guard view.superview != nil else { return nil }
            let frame = view.convert(view.bounds, to: canvas)
            if y < frame.minY {
                high = middle - 1
            } else if y > frame.maxY {
                low = middle + 1
            } else {
                return middle
            }
        }
        return nil
    }
}
