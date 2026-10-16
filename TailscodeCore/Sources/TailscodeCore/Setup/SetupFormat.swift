import Foundation

/// Numbers a checklist says aloud, written once so a size or a wait reads the same on every desk and
/// in every language: bytes in the unit a person thinks in, a wait in the nearest honest round
/// figure, a fraction as a percentage in the reader's own notation.
public enum SetupFormat {
    private static let unitStep = 1024.0

    private enum Unit: Int, CaseIterable {
        case kilobyte, megabyte, gigabyte, terabyte

        var label: String {
            switch self {
            case .kilobyte: return "KB"
            case .megabyte: return "MB"
            case .gigabyte: return "GB"
            case .terabyte: return "TB"
            }
        }

        var size: Double { pow(unitStep, Double(rawValue + 1)) }
    }

    /// `44 GB`, `1.5 GB`, `820 MB`: two significant digits are enough for a download a person decides
    /// about, so anything from ten up is whole and anything under ten keeps one decimal.
    public static func bytes(_ count: Int64, locale: Locale = .current) -> String {
        let unit = Self.unit(for: Double(max(0, count)))
        return "\(number(Double(max(0, count)) / unit.size, locale: locale)) \(unit.label)"
    }

    /// `11 of 44 GB`: the unit is the total's, so both figures are in the same one.
    public static func progress(done: Int64, total: Int64, locale: Locale = .current) -> String {
        let unit = Self.unit(for: Double(max(0, total)))
        let have = number(Double(max(0, min(done, total))) / unit.size, locale: locale)
        let all = number(Double(max(0, total)) / unit.size, locale: locale)
        return Localized.text("%1$@ of %2$@ %3$@", have, all, unit.label)
    }

    /// `about 12 minutes`: a wait is never given to the second, because the machine's rate is not
    /// steady enough to deserve it.
    public static func duration(seconds: TimeInterval, locale: Locale = .current) -> String {
        let span = max(0, seconds)
        if span < 45 { return Localized.text("less than a minute") }
        let minutes = Int((span / 60).rounded())
        if minutes < 90 {
            return minutes <= 1
                ? Localized.text("about 1 minute")
                : Localized.text("about %@ minutes", number(Double(minutes), locale: locale))
        }
        let hours = Int((span / 3600).rounded())
        return hours <= 1
            ? Localized.text("about 1 hour")
            : Localized.text("about %@ hours", number(Double(hours), locale: locale))
    }

    public static func duration(minutes: Int, locale: Locale = .current) -> String {
        duration(seconds: TimeInterval(minutes) * 60, locale: locale)
    }

    /// `31%`, in the reader's own notation.
    public static func percent(_ fraction: Double, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        let clamped = min(max(fraction.isFinite ? fraction : 0, 0), 1)
        return formatter.string(from: NSNumber(value: clamped)) ?? "\(Int((clamped * 100).rounded()))%"
    }

    /// Mebibytes as the machine reports them, written as a size: `96 GB`.
    public static func megabytes(_ count: Int64, locale: Locale = .current) -> String {
        bytes(max(0, count) * 1_048_576, locale: locale)
    }

    static func number(_ value: Double, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = value >= 10 ? 0 : 1
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(Int(value.rounded()))
    }

    private static func unit(for bytes: Double) -> Unit {
        var chosen = Unit.kilobyte
        for unit in Unit.allCases where bytes >= unit.size { chosen = unit }
        return chosen
    }
}
