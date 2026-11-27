import AppKit
import MidgarUI
import SwiftUI
import TailscodeCore

/// Escape closes the sheet like its Done button.
private final class UsageCountsWindow: NSWindow {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// MidgarKit's Usage Counts screen as a sheet on the settings window: what the App Store build counts,
/// the switch that turns it off, and the public numbers. A sheet has no title bar for the screen's own
/// toolbar, so the sheet carries the title above it and a Done button below it.
@MainActor
final class UsageCountsSheet: NSObject {
    private static var open: UsageCountsSheet?

    private let window: UsageCountsWindow
    private weak var parent: NSWindow?

    static let size = NSSize(width: 460, height: 560)

    private override init() {
        window = UsageCountsWindow(
            contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.titled],
            backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.title = MidgarUsageCounts.title
        window.onCancel = { [weak self] in self?.finish() }
        window.contentView = makeContent()
    }

    /// Opens the screen on `parent`, once: a second press while it is open does nothing.
    static func present(on parent: NSWindow) {
        guard open == nil else { return }
        let sheet = UsageCountsSheet()
        open = sheet
        sheet.parent = parent
        parent.beginSheet(sheet.window) { _ in
            MainThread.call { open = nil }
        }
    }

    private func finish() {
        guard let parent, window.sheetParent === parent else { return }
        parent.endSheet(window)
    }

    private func makeContent() -> NSView {
        let title = NSTextField(labelWithString: MidgarUsageCounts.title)
        title.font = MacTheme.Ramp.font(.panelLabel)
        let screen = NSHostingView(rootView: NavigationStack { MidgarUsageCounts() })
        let separator = NSBox()
        separator.boxType = .separator
        let done = RowKit.ActionButton(title: Localized.text("Done")) { [weak self] in
            self?.finish()
        }
        done.keyEquivalent = "\r"
        done.setAccessibilityIdentifier("usageCounts.done")
        let footer = NSStackView(views: [RowKit.spacer(), done])
        footer.orientation = NSUserInterfaceLayoutOrientation.horizontal
        let root = NSView()
        for item in [title, screen, separator, footer] as [NSView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(item)
        }
        let inset = MacTheme.Spacing.m
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.size.width),
            root.heightAnchor.constraint(equalToConstant: Self.size.height),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: inset),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            title.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -inset),
            screen.topAnchor.constraint(equalTo: title.bottomAnchor, constant: MacTheme.Spacing.s),
            screen.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            screen.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            screen.bottomAnchor.constraint(equalTo: separator.topAnchor),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: MacTheme.Spacing.s),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -MacTheme.Spacing.s),
        ])
        return root
    }
}
