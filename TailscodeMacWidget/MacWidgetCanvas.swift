import AppKit

/// The widget's drawing layer is one file on both desks — `UsageWidgetViews.swift` is compiled into
/// the phone's extension and this one rather than copied — and the single word it speaks that AppKit
/// does not is the platform's own page colour. Naming it here is what keeps a Mac widget and a Home
/// Screen widget rendering from the same source instead of from two copies that drift apart.
extension NSColor {
    static var systemBackground: NSColor { .windowBackgroundColor }
}
