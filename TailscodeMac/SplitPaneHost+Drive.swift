import AppKit
import TailscodeCore

#if DEBUG
    extension SplitPaneHost {
        /// The tree as the driver reads it: how many panes, what shape, which holds the focus and
        /// in what reading order, by the first characters of each pane's id.
        func driveOrder(_ label: String) -> String {
            let order = layout.paneIDs.map { String($0.raw.prefix(4)) }.joined(separator: ",")
            let focus = layout.paneIDs.firstIndex(of: layout.focusedPane) ?? -1
            return
                "\(label) panes=\(layout.paneCount) shape=\(SplitEven.shape(of: layout)) "
                + "focus=\(focus) zoom=\(layout.zoomedPane != nil) order=\(order)"
        }

        /// Every pane's frame in the tree's own coordinates, top-left origin, in reading order.
        func driveGeometry() -> String {
            view.layoutSubtreeIfNeeded()
            let frames = orderedPanes.enumerated().map { index, pane -> String in
                let rect = pane.view.convert(pane.view.bounds, to: view)
                let top = view.isFlipped ? rect.minY : view.bounds.height - rect.maxY
                return String(
                    format: "%d(%.0f,%.0f %.0fx%.0f)", index, rect.minX, top, rect.width,
                    rect.height)
            }
            return
                "GEOM \(frames.joined(separator: " ")) canvas=\(Int(view.bounds.width))x\(Int(view.bounds.height))"
        }

        /// What VoiceOver would be told about each divider, in reading order, and whether it holds
        /// the keyboard.
        func driveDividers() -> String {
            let lines = layout.splitIDs.enumerated().compactMap { index, id -> String? in
                guard let splitView = splitViews[id] as? DividerSplitView,
                    let element = (splitView.accessibilityChildren() ?? []).compactMap({
                        $0 as? DividerAccessibilityElement
                    }).first
                else { return nil }
                let value = (element.accessibilityValue() as? NSNumber)?.doubleValue ?? -1
                let low = (element.accessibilityMinValue() as? NSNumber)?.doubleValue ?? -1
                let high = (element.accessibilityMaxValue() as? NSNumber)?.doubleValue ?? -1
                let actual =
                    splitView.arrangedSubviews.first.map {
                        splitView.isVertical ? $0.frame.width : $0.frame.height
                    } ?? -1
                return String(
                    format: "%d role=%@ pos=%.0f actual=%.0f range=%.0f...%.0f focused=%d \"%@\" \"%@\"",
                    index, element.accessibilityRole()?.rawValue ?? "-", value, actual, low, high,
                    element.isAccessibilityFocused() ? 1 : 0,
                    element.accessibilityLabel() ?? "-",
                    element.accessibilityValueDescription() ?? "-")
            }
            return "DIVIDERS \(lines.count) " + lines.joined(separator: " | ")
        }

        /// A key on divider `index` without a keyboard: it takes focus and moves as a key would.
        func driveDivider(_ index: Int, key: DividerKey) -> Bool {
            let ids = layout.splitIDs
            guard ids.indices.contains(index), let splitView = splitViews[ids[index]] else {
                return false
            }
            view.window?.makeFirstResponder(splitView)
            return moveDivider(ids[index], by: key)
        }

        /// A strip carried over another pane without a pointer: the highlight is drawn where
        /// letting go would put the pane, captioned with the move it would make.
        func drivePaneHover(target: Int, u: Double, v: Double, source: Int) -> String {
            let panes = orderedPanes
            guard panes.indices.contains(target), panes.indices.contains(source) else {
                return "PDRAG no-target"
            }
            let pane = panes[target]
            let zone = PaneDropTarget.zone(
                x: u * Double(pane.view.bounds.width), y: v * Double(pane.view.bounds.height),
                width: Double(pane.view.bounds.width), height: Double(pane.view.bounds.height))
            guard target != source else {
                clearDropHighlight()
                return "PDRAG - caption=-"
            }
            showDropHighlight(zone, on: pane, caption: zone.moveVerb)
            return "PDRAG \(target) \(zone) caption=\(zone.moveVerb)"
        }

        /// A strip dropped on another pane: `target` and `source` are reading-order indexes and
        /// `u`, `v` where in the target the pointer is, as fractions from its top-left.
        func drivePaneDrop(target: Int, u: Double, v: Double, source: Int) -> String {
            let panes = orderedPanes
            guard panes.indices.contains(target), panes.indices.contains(source),
                let moving = id(of: panes[source])
            else { return "PDROP no-target" }
            let pane = panes[target]
            let zone = PaneDropTarget.zone(
                x: u * Double(pane.view.bounds.width), y: v * Double(pane.view.bounds.height),
                width: Double(pane.view.bounds.width), height: Double(pane.view.bounds.height))
            let took = receivePaneDrop(PaneMovePayload(pane: moving), on: pane, zone: zone)
            return "PDROP took=\(took) zone=\(zone) panes=\(paneCount)"
        }
    }
#endif
