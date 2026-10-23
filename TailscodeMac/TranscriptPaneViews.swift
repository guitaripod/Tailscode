import AppKit
import os
import CodingAgentKit
import TailscodeCore

/// A clip view whose origin is the top, so a transcript grows downwards like a terminal instead
/// of upwards like a default AppKit document.
final class FlippedClipView: NSClipView {
    nonisolated override var isFlipped: Bool { true }
}

/// Forwards drag-destination events to the transcript so the tiling host can treat every pane as
/// a place a chat can land.
final class DropForwardingView: NSView {
    weak var owner: TranscriptViewController?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        owner?.adoptEffectiveAppearance()
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        owner?.onDragEntered?(sender) == true ? operation(for: sender) : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let accepted = owner?.onDragUpdated?(sender), !accepted.isEmpty else { return [] }
        return operation(for: sender)
    }

    /// A pane in flight moves; a chat in flight is opened where it lands, which AppKit spells copy.
    private func operation(for sender: any NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.types?.contains(.tailscodePane) == true ? .move : .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        owner?.onDragExited?()
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        true
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        owner?.onDragPerform?(sender) ?? false
    }
}
