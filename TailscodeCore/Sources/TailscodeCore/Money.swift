import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Money as the person reading it counts it. Every figure this app states about a conversation is
/// an estimate priced in dollars, what the tokens would have cost on the metered API, so which
/// currency it is said in is presentation and nothing else: the dollars are converted at the
/// European Central Bank's daily reference rate and written the way the person's locale writes
/// money. A balance a provider bills is never converted here; it stays in the currency it is
/// owed in (`QuotaGlance.money`).
///
/// With no rate known, a currency the bank does not quote, or dollars chosen, the figure is the
/// dollars exactly as they were always written, so nothing is ever shown at a rate that was
/// guessed.
public enum Money {
    private static let formatterLock = NSLock()
    nonisolated(unsafe) private static var formatters: [String: (formatter: NumberFormatter, places: Int)] = [:]

    /// The currencies written without a minor unit: the ones that have none, and the two whose
    /// hundredths nobody prices in. A formatter does not learn this from a code set on it.
    static let wholeOnly: Set<String> = ["JPY", "KRW", "ISK", "HUF", "IDR"]

    /// A check or a bench is running: every figure is dollars, whatever the machine is set to,
    /// so it reads the same everywhere.
    nonisolated(unsafe) public static var speaksDollarsOnly = false

    /// An estimate in dollars, said in the person's currency at the precision it is worth
    /// reading: two places below a hundred, whole above, and a floor so a turn that cost a
    /// hundredth of a cent says so rather than reading as free.
    public static func estimate(_ usd: Double) -> String {
        guard !speaksDollarsOnly else { return dollars(usd) }
        let code = MoneySetting.code
        guard code != "USD" else { return dollars(usd) }
        CurrencyRates.shared.refreshIfStale()
        guard let rate = CurrencyRates.shared.rate(fromDollarsTo: code) else { return dollars(usd) }
        return local(usd * rate, code: code, locale: .current)
    }

    /// The same estimate with the mark that says it was priced rather than billed.
    public static func approximate(_ usd: Double) -> String { "~" + estimate(usd) }

    /// Whether a line states money: dollars, or the currency estimates are being said in.
    public static func appears(in line: String) -> Bool {
        if line.contains("$") { return true }
        let code = MoneySetting.code
        guard code != "USD" else { return false }
        formatterLock.lock()
        defer { formatterLock.unlock() }
        let symbols = formatters.filter { $0.key.hasPrefix(code + "|") }.map(\.value.formatter.currencySymbol)
        return line.contains(code) || symbols.contains { symbol in symbol.map { line.contains($0) } ?? false }
    }

    /// Dollars as this app has always written them.
    public static func dollars(_ value: Double) -> String {
        if value <= 0 { return "$0" }
        if value < 0.01 { return "<$0.01" }
        if value < 100 { return String(format: "$%.2f", value) }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.maximumFractionDigits = 0
        return "$" + (formatter.string(from: NSNumber(value: value.rounded())) ?? String(format: "%.0f", value))
    }

    /// An amount already in `code`, written as `locale` writes money. A currency with no minor
    /// unit (yen, won, krónur) is always whole.
    static func local(_ value: Double, code: String, locale: Locale) -> String {
        formatterLock.lock()
        defer { formatterLock.unlock() }
        let key = code + "|" + locale.identifier
        let formatter: NumberFormatter
        if let held = formatters[key] {
            formatter = held.formatter
        } else {
            formatter = NumberFormatter()
            formatter.locale = locale
            formatter.numberStyle = .currency
            formatter.currencyCode = code
            formatters[key] = (formatter, wholeOnly.contains(code) ? 0 : 2)
        }
        let places = formatters[key]?.places ?? 2
        let smallest = places > 0 ? pow(10, -Double(places)) : 1
        func written(_ amount: Double, places: Int) -> String {
            formatter.minimumFractionDigits = places
            formatter.maximumFractionDigits = places
            return formatter.string(from: NSNumber(value: amount)) ?? "\(amount) \(code)"
        }
        if value <= 0 { return written(0, places: 0) }
        if value < smallest { return "<" + written(smallest, places: places) }
        if places > 0, value < 100 { return written(value, places: places) }
        return written(value.rounded(), places: 0)
    }
}

/// Which currency estimates are said in: the one the device's region uses unless the person
/// chose one. A desk whose locale is not its owner's country (an English system in Finland) is
/// why there is a choice at all.
public enum MoneySetting {
    public static let key = "tailscode.money.currency"
    public static let didChange = Notification.Name("tailscode.money.didChange")

    /// The code the person chose, nil for the region's own.
    public static var chosen: String? {
        let held = UserDefaults.standard.string(forKey: key) ?? ""
        return held.isEmpty || held == "auto" ? nil : held
    }

    public static func choose(_ code: String?) {
        UserDefaults.standard.set(code ?? "auto", forKey: key)
        StoreNotice.post(didChange)
    }

    /// The region's currency, dollars where the locale names none.
    public static var regional: String { Locale.current.currency?.identifier ?? "USD" }

    public static var code: String { chosen ?? regional }

    public static var title: String { Localized.text("Currency") }

    public static var explanation: String {
        Localized.text(
            "What a turn or a conversation cost is an estimate priced in US dollars. It is shown in this currency at the European Central Bank's daily rate; a balance a provider bills keeps its own.")
    }

    public static func automatic(_ code: String) -> String { Localized.text("Automatic (%@)", code) }

    /// The currencies a person can choose: dollars, and every one the bank quotes, by code.
    public static var choices: [String] {
        (["USD", "EUR"] + CurrencyRates.shared.quoted).reduce(into: [String]()) { list, code in
            if !list.contains(code) { list.append(code) }
        }
    }

    /// A code with its name in the person's language: "EUR \u{00B7} Euro".
    public static func label(_ code: String) -> String {
        guard let name = Locale.current.localizedString(forCurrencyCode: code), name != code else { return code }
        return "\(code) \u{00B7} \(name)"
    }
}

/// The European Central Bank's daily reference rates, fetched at most twice a day and only while
/// a currency other than dollars is being shown. The request carries nothing: it is a public
/// document. The table is kept on the device so a launch without a network still converts at the
/// last known rate, and a table older than ten days is not used at all.
public final class CurrencyRates: @unchecked Sendable {
    public static let shared = CurrencyRates()
    public static let source = URL(string: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml")!
    static let storeKey = "tailscode.money.rates"
    static let refreshEvery: TimeInterval = 12 * 3600
    static let retryAfter: TimeInterval = 3600
    static let goodFor: TimeInterval = 10 * 86400

    struct Table: Codable, Equatable {
        /// Units of each currency one euro buys.
        var perEuro: [String: Double]
        var fetchedAt: Date
    }

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let clock: @Sendable () -> Date
    private let fetch: @Sendable () async -> Data?
    private var table: Table?
    private var loaded = false
    private var fetching = false
    private var lastAttempt: Date?

    public init(
        defaults: UserDefaults = .standard, clock: @escaping @Sendable () -> Date = { Date() },
        fetch: @escaping @Sendable () async -> Data? = CurrencyRates.download
    ) {
        self.defaults = defaults
        self.clock = clock
        self.fetch = fetch
    }

    public static let download: @Sendable () async -> Data? = {
        var request = URLRequest(url: source)
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return data
    }

    private func held() -> Table? {
        lock.withLock {
            if !loaded {
                loaded = true
                table = defaults.data(forKey: Self.storeKey).flatMap { try? JSONDecoder().decode(Table.self, from: $0) }
            }
            return table
        }
    }

    /// How many units of `code` a dollar buys, or nil when the bank's table is missing, too old,
    /// or does not quote it.
    public func rate(fromDollarsTo code: String) -> Double? {
        guard let table = held(), clock().timeIntervalSince(table.fetchedAt) < Self.goodFor,
            let dollars = table.perEuro["USD"], dollars > 0
        else { return nil }
        if code == "EUR" { return 1 / dollars }
        guard let other = table.perEuro[code], other > 0 else { return nil }
        return other / dollars
    }

    /// The codes the last table quoted, sorted.
    public var quoted: [String] { (held()?.perEuro.keys.sorted()) ?? [] }

    /// Fetches the table when the one held is older than half a day, one request at a time, and
    /// leaves a failed attempt alone for an hour.
    public func refreshIfStale() {
        let now = clock()
        let current = held()
        let due = lock.withLock { () -> Bool in
            guard !fetching else { return false }
            if let current, now.timeIntervalSince(current.fetchedAt) < Self.refreshEvery { return false }
            if let lastAttempt, now.timeIntervalSince(lastAttempt) < Self.retryAfter { return false }
            fetching = true
            lastAttempt = now
            return true
        }
        guard due else { return }
        Task.detached { [self] in
            let data = await fetch()
            let parsed = data.flatMap { Self.read($0) }
            let changed = lock.withLock { () -> Bool in
                fetching = false
                guard let parsed, !parsed.isEmpty else { return false }
                let next = Table(perEuro: parsed, fetchedAt: clock())
                table = next
                loaded = true
                if let encoded = try? JSONEncoder().encode(next) { defaults.set(encoded, forKey: Self.storeKey) }
                return true
            }
            if changed { StoreNotice.post(MoneySetting.didChange) }
        }
    }

    /// The bank's document read into units per euro: every `currency='XXX' rate='1.23'` pair.
    static func read(_ data: Data) -> [String: Double]? {
        guard let text = String(data: data, encoding: .utf8),
            let expression = try? NSRegularExpression(pattern: "currency=['\"]([A-Z]{3})['\"]\\s+rate=['\"]([0-9.]+)['\"]")
        else { return nil }
        var rates: [String: Double] = [:]
        let range = NSRange(text.startIndex..., in: text)
        for match in expression.matches(in: text, range: range) {
            guard let code = Range(match.range(at: 1), in: text), let rate = Range(match.range(at: 2), in: text),
                let value = Double(text[rate]), value > 0
            else { continue }
            rates[String(text[code])] = value
        }
        return rates.isEmpty ? nil : rates
    }
}
