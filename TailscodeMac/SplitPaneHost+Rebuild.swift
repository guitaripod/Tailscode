import AppKit
import TailscodeCore

extension SplitPaneHost {
    /// Rebuilds the controller skeleton around the surviving panes. Panes detach first so no
    /// `NSSplitViewItem` still claims them when they join the new tree, and the ratios are asserted
    /// twice on purpose: once here, so a tree that already has an extent is never painted at
    /// `NSSplitView`'s own even distribution and then jumped to the real arrangement a frame later,
    /// and once on the next turn for the tree that had no extent yet.
    func rebuild() {
        suppressCapture = true
        for pane in panes.values {
            pane.removeFromParent()
            pane.view.removeFromSuperview()
        }
        if let treeRoot {
            treeRoot.removeFromParent()
            treeRoot.view.removeFromSuperview()
        }
        for splitView in splitViews.values {
            NotificationCenter.default.removeObserver(
                self, name: NSSplitView.didResizeSubviewsNotification, object: splitView)
        }
        splitViews = [:]
        splitItems = [:]
        splitLeaves = [:]
        let built = build(layout.root)
        addChild(built)
        built.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(built.view, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            built.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            built.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            built.view.topAnchor.constraint(equalTo: view.topAnchor),
            built.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        treeRoot = built
        applyZoom()
        applyFocusStyling()
        applyIdentity()
        settleRatios()
    }

    private func build(_ node: SplitNode) -> NSViewController {
        switch node {
        case .pane(let id):
            guard let pane = panes[id] else { return NSViewController() }
            pane.removeFromParent()
            pane.view.removeFromSuperview()
            return pane
        case .split(let id, let axis, _, let first, let second):
            let controller = NSSplitViewController()
            let splitView = DividerSplitView()
            splitView.onDividerDoubleClick = { [weak self] in self?.equalize() }
            splitView.onDividerKey = { [weak self] key in self?.moveDivider(id, by: key) ?? false }
            splitView.accessibilityReading = { [weak self] in self?.dividerReading(id) }
            controller.splitView = splitView
            controller.splitView.isVertical = axis == .horizontal
            controller.splitView.dividerStyle = .thin
            let firstItem = NSSplitViewItem(viewController: build(first))
            let secondItem = NSSplitViewItem(viewController: build(second))
            for item in [firstItem, secondItem] {
                item.minimumThickness = paneFloor(axis)
                item.canCollapse = false
            }
            controller.addSplitViewItem(firstItem)
            controller.addSplitViewItem(secondItem)
            splitViews[id] = controller.splitView
            splitItems[id] = (firstItem, secondItem)
            splitLeaves[id] = (Set(Self.leaves(of: first)), Set(Self.leaves(of: second)))
            NotificationCenter.default.addObserver(
                self, selector: #selector(splitResized(_:)),
                name: NSSplitView.didResizeSubviewsNotification, object: controller.splitView)
            return controller
        }
    }

    /// The floor a pane is held to, which is the promised extent only while the tree has room to
    /// promise it to every pane at once. A required minimum the surface cannot satisfy is not a
    /// floor: it is a broken constraint, and what comes out of it is an arrangement of uneven panes
    /// that no drag can even out.
    func paneFloor(_ axis: SplitAxis) -> CGFloat {
        let ideal: CGFloat =
            axis == .horizontal ? CGFloat(PaneDropTarget.minimumPaneExtent) : 160
        let extent = axis == .horizontal ? view.bounds.width : view.bounds.height
        guard extent > 0 else { return ideal }
        let count = CGFloat(max(1, layout.paneCount))
        return min(ideal, (extent - (count - 1) * CGFloat(PaneSizing.gutter)) / count)
    }

    private static func leaves(of node: SplitNode) -> [PaneID] {
        switch node {
        case .pane(let id): return [id]
        case .split(_, _, _, let first, let second):
            return leaves(of: first) + leaves(of: second)
        }
    }

    /// Positions from ratios, asserted after layout so the split has an extent to divide, and
    /// walked outermost-first with a layout pass after each divider — a nested split only learns
    /// its new extent once its parent's position has actually landed, so any other order divides
    /// an extent the tree is about to stop having.
    /// Whether every divider was already where the tree puts it, so nothing was left to correct.
    @discardableResult
    func applyRatios() -> Bool {
        let held = suppressCapture
        suppressCapture = true
        defer { suppressCapture = held }
        view.layoutSubtreeIfNeeded()
        var settled = true
        applyRatios(layout.root, placement: currentPlacement(), settled: &settled)
        return settled
    }

    private func applyRatios(_ node: SplitNode, placement: PanePlacement, settled: inout Bool) {
        guard case .split(let id, _, let ratio, let first, let second) = node else { return }
        if let splitView = splitViews[id] {
            let extent = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
            if extent > 50 {
                let position =
                    placement.divider(id)?.position
                    ?? Double((extent - splitView.dividerThickness) * ratio)
                let before = splitView.arrangedSubviews.first.map {
                    splitView.isVertical ? $0.frame.width : $0.frame.height
                }
                splitView.setPosition(CGFloat(position), ofDividerAt: 0)
                splitView.layoutSubtreeIfNeeded()
                let after = splitView.arrangedSubviews.first.map {
                    splitView.isVertical ? $0.frame.width : $0.frame.height
                }
                if before.map({ abs(Double($0) - position) > 1 }) ?? true
                    || after.map({ abs(Double($0) - position) > 1 }) ?? true
                {
                    settled = false
                }
            }
        }
        applyRatios(first, placement: placement, settled: &settled)
        applyRatios(second, placement: placement, settled: &settled)
    }

    /// AppKit redistributes a nested split's thickness as the one above it moves, so a position
    /// written once can be undone by the layout it causes. Writing the tree's positions again
    /// until a pass finds every divider already there is what leaves it there; the passes are a
    /// few frames apart and give up after a handful, because a floor that cannot be honoured is
    /// a clamp, not a race.
    func settleRatios() {
        suppressCapture = true
        if applyRatios() {
            suppressCapture = false
            return
        }
        settle(attempt: 1)
    }

    private func settle(attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(30)) { [weak self] in
            guard let self else { return }
            if self.applyRatios() || attempt >= 8 {
                self.suppressCapture = false
            } else {
                self.settle(attempt: attempt + 1)
            }
        }
    }

    /// A divider drag settles into the model as a ratio, exactly the way the window's own
    /// dividers persist — mid-collapse widths that are nobody's intent are ignored, and so is every
    /// resize the person did not make with a divider: a window resize, a zoom, a rebuild. Only a
    /// ratio that actually moved is written, and the write trails the drag.
    @objc private func splitResized(_ notification: Notification) {
        guard !suppressCapture, Self.isDividerDrag(notification),
            let splitView = notification.object as? NSSplitView,
            let id = splitViews.first(where: { $0.value === splitView })?.key,
            let firstView = splitView.arrangedSubviews.first
        else { return }
        let extent = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        let position = splitView.isVertical ? firstView.frame.width : firstView.frame.height
        guard extent > 150, position > 40, position < extent - 40 else { return }
        let share = position / (extent - splitView.dividerThickness)
        guard abs((layout.ratio(of: id) ?? -1) - share) > 0.001 else { return }
        let placement = currentPlacement()
        if let divider = placement.divider(id) {
            let coordinate = Double(share)
                * (divider.parent.extent(along: divider.axis) - PaneSizing.gutter)
            layout.drag(id, to: coordinate, in: placement)
            if coordinate < divider.lowest - 1 || coordinate > divider.highest + 1 {
                settleRatios()
            }
        } else {
            layout.setRatio(Double(share), of: id)
        }
        ratioCaptures += 1
        schedulePersist()
    }

    /// `NSSplitView` names the divider in the notification only when a divider is being dragged,
    /// and a drag is a mouse gesture; a resize from anywhere else carries neither.
    private static func isDividerDrag(_ notification: Notification) -> Bool {
        guard notification.userInfo?["NSSplitViewDividerIndex"] != nil else { return false }
        switch NSApp?.currentEvent?.type {
        case .leftMouseDragged, .leftMouseDown, .leftMouseUp: return true
        default: return false
        }
    }

    /// The zoom is collapse along the tree: every split hides the side that does not contain the
    /// zoomed pane, so one conversation borrows the whole surface and unzooming shows everything
    /// exactly where it was.
    func applyZoom() {
        let zoomed = layout.zoomedPane
        for (id, items) in splitItems {
            guard let zoomed, let leaves = splitLeaves[id] else {
                items.first.isCollapsed = false
                items.second.isCollapsed = false
                continue
            }
            items.first.isCollapsed = leaves.second.contains(zoomed)
            items.second.isCollapsed = leaves.first.contains(zoomed)
        }
        applyParking()
    }

    /// A pane nobody can see owns no stream and no clock: zoomed away, the window not visible, or
    /// parked by the governor. Showing it again takes its chat back.
    func applyParking() {
        let zoomed = layout.zoomedPane
        for (id, pane) in panes {
            let hidden = zoomed != nil && zoomed != id
            pane.setParked(occluded || hidden || governorParked.contains(id))
        }
    }

    /// Whether the window is visible at all, from its occlusion state.
    func setOccluded(_ occluded: Bool) {
        guard occluded != self.occluded else { return }
        self.occluded = occluded
        if !occluded { governorParked = [] }
        applyParking()
    }

    /// The governor's parked panes, from the seatbelts' one-second decision.
    func applyGovernor(_ decision: GovernorDecision) {
        let parked = Set(decision.densities.filter { $0.value == .parked }.keys)
        guard parked != governorParked else { return }
        governorParked = parked
        applyParking()
    }

    /// The canvas's verbs, answered by restructuring the tree and rebuilding the controllers around
    /// it the way every structural verb here does.
    @discardableResult
    func cycleFocus(forward: Bool) -> Bool {
        let wasZoomed = layout.zoomedPane != nil
        guard layout.cycleFocus(forward: forward) != nil else { return false }
        if wasZoomed { applyZoom() }
        applyFocusStyling()
        onFocusChanged?()
        persist()
        return true
    }

    func promoteActive() {
        guard layout.promote(layout.focusedPane) else { return }
        rebuild()
        onFocusChanged?()
        persist()
    }
}
