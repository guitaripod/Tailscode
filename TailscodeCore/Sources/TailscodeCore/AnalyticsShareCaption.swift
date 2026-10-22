import Foundation

extension AnalyticsShare {
    /// The most characters a post may carry, counted the way X counts them (``xLength(_:)``).
    public static let captionLimit = 280
    /// The most characters an image description may carry on X.
    public static let altTextLimit = 1000

    /// Words to post with the picture: the headline and window, the trend, then what the chosen
    /// modules say, most striking first, as many as fit in a post. Plain text, no hashtags and no
    /// links. Every phrase is one the usage screen already writes; the estimate line is held back
    /// first and goes last, because a dollar figure with no word on what it is reads as a bill.
    public func caption(_ selection: ShareSelection) -> String {
        let shown = selection.fit(analytics).shown
        var head = "\(analytics.headline) · \(analytics.windowLabel)"
        if let delta = analytics.deltaLine { head += "\n\(delta)" }
        let estimate = analytics.headline == analytics.totalMoney
            ? Localized.text("API-equivalent estimate · not a bill") : nil
        var lines = [head]
        let reserve = estimate.map { Self.xLength("\n" + $0) } ?? 0
        for module in ShareModule.priority where shown.contains(module) {
            guard let line = captionLine(for: module) else { continue }
            let candidate = (lines + [line]).joined(separator: "\n")
            if Self.xLength(candidate) + reserve <= Self.captionLimit { lines.append(line) }
        }
        if let estimate {
            let candidate = (lines + [estimate]).joined(separator: "\n")
            if Self.xLength(candidate) <= Self.captionLimit { lines.append(estimate) }
        }
        return Self.clipped(lines.joined(separator: "\n"), limit: Self.captionLimit) {
            Self.xLength($0)
        }
    }

    /// A description of the picture for people who cannot see it: the headline and window, then
    /// each shown module in the order the picture draws them, in words and numbers, then what
    /// the footer says. At most ``altTextLimit`` characters, cut at the end of a sentence.
    public func altText(_ selection: ShareSelection) -> String {
        let shown = selection.fit(analytics).shown
        var parts = [
            Localized.text("Tailscode usage card"),
            "\(analytics.window.surfaceTitle): \(analytics.headline), \(analytics.windowLabel).",
        ]
        if let delta = analytics.deltaLine { parts.append("\(delta).") }
        parts.append("\(analytics.perDayLine).")
        parts.append("\(Localized.text("API-equivalent estimate · not a bill")).")
        if let coverage = analytics.coverageNote { parts.append(coverage) }
        if !analytics.missingServers.isEmpty {
            parts.append(
                Localized.text("Not counted: %@", analytics.missingServers.joined(separator: ", ")))
        }
        for module in ShareModule.selectable where shown.contains(module) {
            if let text = altLine(for: module) { parts.append(text) }
        }
        return Self.clipped(parts.joined(separator: " "), limit: Self.altTextLimit) { $0.count }
    }

    private func captionLine(for module: ShareModule) -> String? {
        switch module {
        case .hero: return nil
        case .activity: return analytics.activityLine
        case .daily:
            guard let peak = analytics.peakDay, peak.share > 0 else { return nil }
            return Localized.text("Peak %@ · %@", peak.title, peak.value)
        case .week:
            guard let busiest = analytics.weekdays.max(by: { $0.share < $1.share }),
                busiest.share > 0, let money = busiest.money
            else { return nil }
            return Localized.text("Busiest on %@ · %@", busiest.label, money)
        case .models: return list(Localized.text("Models"), analytics.models, count: 3)
        case .providers: return list(Localized.text("Providers"), analytics.providers, count: 3)
        case .projects: return list(Localized.text("Projects"), analytics.projects, count: 3)
        case .tools: return list(Localized.text("Tools"), analytics.tools, count: 3)
        case .tokens: return analytics.cacheLine
        case .records:
            let rows = analytics.records.filter { $0.id != "busiestDay" }.prefix(2)
            return rows.isEmpty ? nil : rows.map { "\($0.title): \($0.value)" }.joined(separator: " · ")
        case .insights: return AnalyticsShare.standouts(analytics).first
        }
    }

    private func altLine(for module: ShareModule) -> String? {
        switch module {
        case .hero: return nil
        case .activity: return "\(module.title): \(analytics.activityLine)."
        case .daily:
            guard let first = analytics.days.first, let last = analytics.days.last,
                let peak = analytics.peakDay, peak.share > 0
            else { return nil }
            let end = last.isToday ? Localized.text("Today") : last.title
            return "\(analytics.window.chartTitle): \(first.title) – \(end). "
                + "\(Localized.text("Peak %@ · %@", peak.title, peak.value))."
        case .week:
            guard let line = captionLine(for: .week) else { return nil }
            return "\(Localized.text("The week")): \(line)."
        case .models: return meterAlt(Localized.text("Models"), analytics.models)
        case .providers: return meterAlt(Localized.text("Providers"), analytics.providers)
        case .projects: return meterAlt(Localized.text("Projects"), analytics.projects)
        case .tools: return meterAlt(Localized.text("Tools"), analytics.tools)
        case .tokens:
            let tiers = Card.tierMeters(analytics).map { "\($0.label) \($0.money ?? "")" }
            guard !tiers.isEmpty else { return nil }
            let cache = analytics.cacheLine.map { " \($0)." } ?? ""
            return "\(Localized.text("Tokens")): \(tiers.joined(separator: ", ")).\(cache)"
        case .records:
            let rows = analytics.records.prefix(Card.recordLimit).map { record -> String in
                var row = "\(record.title) \(record.value)"
                if let detail = record.detail, !detail.isEmpty { row += " (\(detail))" }
                return row
            }
            return rows.isEmpty ? nil : "\(Localized.text("Records")): \(rows.joined(separator: "; "))."
        case .insights:
            let lines = AnalyticsShare.standouts(analytics).prefix(3)
            return lines.isEmpty ? nil : "\(Localized.text("What stands out")): \(lines.joined(separator: " "))"
        }
    }

    private func list(_ title: String, _ meters: [UsageAnalytics.Meter], count: Int) -> String? {
        guard !meters.isEmpty else { return nil }
        return "\(title): \(meters.prefix(count).map(\.label).joined(separator: ", "))"
    }

    private func meterAlt(_ title: String, _ meters: [UsageAnalytics.Meter]) -> String? {
        guard !meters.isEmpty else { return nil }
        let rows = meters.prefix(Card.meterLimit).map { meter -> String in
            guard let value = meter.money, !value.isEmpty else { return meter.label }
            return "\(meter.label) \(value)"
        }
        return "\(title): \(rows.joined(separator: ", "))."
    }

    /// The text cut to a limit at the end of its last whole sentence or line that fits, and with
    /// an ellipsis where it has to be cut mid-phrase.
    static func clipped(_ text: String, limit: Int, measure: (String) -> Int) -> String {
        guard measure(text) > limit else { return text }
        var kept = text
        while measure(kept + "…") > limit, !kept.isEmpty { kept.removeLast() }
        if let boundary = kept.lastIndex(where: { ".\n".contains($0) }),
            kept.distance(from: kept.startIndex, to: boundary) > kept.count / 2
        {
            return String(kept[...boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return kept.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    /// How long X counts a post to be: a link is 23 whatever its length; a character from a
    /// wide script, an emoji, or a symbol outside the Latin and general-punctuation blocks is 2;
    /// everything else is 1. The same weights X's own twitter-text applies, so a caption that
    /// fits here fits there.
    public static func xLength(_ text: String) -> Int {
        var total = 0
        let normalized = text.precomposedStringWithCanonicalMapping
        var rest = Substring(normalized)
        while !rest.isEmpty {
            if let link = urlRange(in: rest) {
                total += weight(of: rest[..<link.lowerBound]) + 23
                rest = rest[link.upperBound...]
            } else {
                total += weight(of: rest)
                break
            }
        }
        return total
    }

    private static func urlRange(in text: Substring) -> Range<Substring.Index>? {
        guard let start = text.range(of: "http://") ?? text.range(of: "https://") else { return nil }
        let end = text[start.upperBound...].firstIndex { $0.isWhitespace } ?? text.endIndex
        return start.lowerBound..<end
    }

    private static func weight(of text: Substring) -> Int {
        text.reduce(0) { total, character in
            let scalars = character.unicodeScalars
            if scalars.contains(where: { $0.properties.isEmojiPresentation || $0.value == 0xFE0F }) {
                return total + 2
            }
            return total + scalars.reduce(0) { $0 + (isNarrow($1.value) ? 1 : 2) }
        }
    }

    private static func isNarrow(_ value: UInt32) -> Bool {
        value <= 4351 || (8192...8205).contains(value) || (8208...8223).contains(value)
            || (8242...8247).contains(value)
    }
}
