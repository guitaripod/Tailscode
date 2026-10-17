import Foundation

/// "3 minutes ago" without building a formatter for every label.
///
/// A `RelativeDateTimeFormatter` opens an ICU formatter when it is made, which costs far more than
/// the string it hands back, and a list of chat rows asks for one per row on every rebuild. One
/// instance is kept per distinct configuration, the units style and the locale it was made under,
/// so a change of region is a new entry rather than a stale one. A formatter is only ever read
/// once it is made, which is what allows a row model built off the main thread to share it.
enum RelativeDateFormat {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var formatters: [String: RelativeDateTimeFormatter] = [:]

    /// The date as words relative to `reference`. A nil `style` leaves the formatter at its own
    /// default, which is not the same as asking for `.full` by name on every system.
    static func string(
        for date: Date, relativeTo reference: Date = Date(),
        style: RelativeDateTimeFormatter.UnitsStyle? = nil
    ) -> String {
        formatter(style: style).localizedString(for: date, relativeTo: reference)
    }

    private static func formatter(style: RelativeDateTimeFormatter.UnitsStyle?) -> RelativeDateTimeFormatter {
        let key = "\(Locale.current.identifier)|\(style.map { String($0.rawValue) } ?? "default")"
        lock.lock()
        defer { lock.unlock() }
        if let made = formatters[key] { return made }
        let made = RelativeDateTimeFormatter()
        if let style { made.unitsStyle = style }
        formatters[key] = made
        return made
    }
}
