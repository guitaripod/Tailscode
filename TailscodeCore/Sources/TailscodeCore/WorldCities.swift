import Foundation

/// A place a clock can be pinned for. Coordinates are what turn a time zone into a day: the same
/// 14:07 is noon light in one city and the middle of the night in another, and a world clock that
/// cannot say which is a table of numbers. A city without coordinates (UTC) has no sun and says so.
public struct WorldCity: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let country: String
    public let zoneID: String
    public let latitude: Double?
    public let longitude: Double?
    public let aliases: [String]
    public let isApproximate: Bool

    public init(
        id: String, name: String, country: String, zoneID: String, latitude: Double?,
        longitude: Double?, aliases: [String] = [], isApproximate: Bool = false
    ) {
        self.id = id
        self.name = name
        self.country = country
        self.zoneID = zoneID
        self.latitude = latitude
        self.longitude = longitude
        self.aliases = aliases
        self.isApproximate = isApproximate
    }

    public var timeZone: TimeZone? { TimeZone(identifier: zoneID) }

    public var hasSun: Bool { latitude != nil && longitude != nil }
}

/// The catalog the pins are chosen from, and the answer to *where is this desk*.
public enum WorldCities {
    public static let utc = WorldCity(
        id: "utc", name: "UTC", country: "", zoneID: "UTC", latitude: nil, longitude: nil,
        aliases: ["GMT", "Zulu", "Universal"])

    /// The cities a first-time reader is offered when nothing is pinned yet.
    public static let suggestedIDs = ["london", "new-york", "san-francisco", "tokyo"]

    public static func city(_ id: String) -> WorldCity? { byID[id] }

    /// The city standing for the time zone this desk is in. The zone is exact; the coordinates are
    /// the catalog's nearest entry for it, and a zone the catalog has never heard of gets a
    /// meridian-and-mid-latitude guess marked approximate rather than no daylight at all, because a
    /// strip that is a few degrees wrong still shows the shape of the day.
    public static func home(for zone: TimeZone) -> WorldCity {
        if let city = all.first(where: { $0.zoneID == zone.identifier }) {
            return WorldCity(
                id: "home", name: displayName(forZone: zone.identifier), country: city.country,
                zoneID: zone.identifier, latitude: city.latitude, longitude: city.longitude)
        }
        let offsetHours = Double(zone.secondsFromGMT()) / 3600
        let isUniversal = zone.identifier == "UTC" || zone.identifier == "GMT"
            || zone.identifier == "Etc/UTC"
        return WorldCity(
            id: "home", name: displayName(forZone: zone.identifier), country: "",
            zoneID: zone.identifier, latitude: isUniversal ? nil : 45,
            longitude: isUniversal ? nil : offsetHours * 15, isApproximate: !isUniversal)
    }

    /// `Europe/Helsinki` → Helsinki, `America/Argentina/Buenos_Aires` → Buenos Aires.
    public static func displayName(forZone identifier: String) -> String {
        if identifier == "UTC" || identifier == "Etc/UTC" || identifier == "GMT" { return "UTC" }
        let last = identifier.split(separator: "/").last.map(String.init) ?? identifier
        return last.replacingOccurrences(of: "_", with: " ")
    }

    /// Cities matching what was typed, best first: a name that starts with it, a word that starts
    /// with it, then anywhere in the name, an alias, the country or the zone. Accents and case do
    /// not matter, because nobody types Zürich the way the table spells it.
    public static func search(_ query: String, excluding: Set<String> = [], limit: Int = 8)
        -> [WorldCity]
    {
        let needle = fold(query)
        guard !needle.isEmpty else { return [] }
        var ranked: [(Int, WorldCity)] = []
        for city in all where !excluding.contains(city.id) {
            let name = fold(city.name)
            let rank: Int?
            if name.hasPrefix(needle) {
                rank = 0
            } else if name.split(separator: " ").contains(where: { $0.hasPrefix(needle) }) {
                rank = 1
            } else if name.contains(needle) {
                rank = 2
            } else if city.aliases.contains(where: { fold($0).hasPrefix(needle) }) {
                rank = 3
            } else if fold(city.country).hasPrefix(needle) {
                rank = 4
            } else if fold(city.zoneID).contains(needle) {
                rank = 5
            } else {
                rank = nil
            }
            if let rank { ranked.append((rank, city)) }
        }
        return ranked
            .enumerated()
            .sorted { lhs, rhs in
                lhs.element.0 == rhs.element.0
                    ? lhs.offset < rhs.offset : lhs.element.0 < rhs.element.0
            }
            .prefix(limit)
            .map(\.element.1)
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
    }

    private static let byID: [String: WorldCity] = {
        var table: [String: WorldCity] = [:]
        for city in all { table[city.id] = city }
        table[utc.id] = utc
        return table
    }()

    private static func c(
        _ id: String, _ name: String, _ country: String, _ zone: String, _ lat: Double,
        _ lon: Double, _ aliases: [String] = []
    ) -> WorldCity {
        WorldCity(
            id: id, name: name, country: country, zoneID: zone, latitude: lat, longitude: lon,
            aliases: aliases)
    }

    public static let all: [WorldCity] = [
        utc,
        c("reykjavik", "Reykjavik", "Iceland", "Atlantic/Reykjavik", 64.15, -21.94),
        c("london", "London", "United Kingdom", "Europe/London", 51.51, -0.13, ["UK", "GMT"]),
        c("dublin", "Dublin", "Ireland", "Europe/Dublin", 53.35, -6.26),
        c("lisbon", "Lisbon", "Portugal", "Europe/Lisbon", 38.72, -9.14),
        c("madrid", "Madrid", "Spain", "Europe/Madrid", 40.42, -3.70),
        c("barcelona", "Barcelona", "Spain", "Europe/Madrid", 41.39, 2.17),
        c("paris", "Paris", "France", "Europe/Paris", 48.86, 2.35),
        c("brussels", "Brussels", "Belgium", "Europe/Brussels", 50.85, 4.35),
        c("amsterdam", "Amsterdam", "Netherlands", "Europe/Amsterdam", 52.37, 4.90),
        c("berlin", "Berlin", "Germany", "Europe/Berlin", 52.52, 13.40),
        c("zurich", "Zurich", "Switzerland", "Europe/Zurich", 47.38, 8.54),
        c("rome", "Rome", "Italy", "Europe/Rome", 41.90, 12.50),
        c("vienna", "Vienna", "Austria", "Europe/Vienna", 48.21, 16.37),
        c("prague", "Prague", "Czechia", "Europe/Prague", 50.08, 14.44),
        c("warsaw", "Warsaw", "Poland", "Europe/Warsaw", 52.23, 21.01),
        c("budapest", "Budapest", "Hungary", "Europe/Budapest", 47.50, 19.04),
        c("stockholm", "Stockholm", "Sweden", "Europe/Stockholm", 59.33, 18.07),
        c("oslo", "Oslo", "Norway", "Europe/Oslo", 59.91, 10.75),
        c("copenhagen", "Copenhagen", "Denmark", "Europe/Copenhagen", 55.68, 12.57),
        c("helsinki", "Helsinki", "Finland", "Europe/Helsinki", 60.17, 24.94),
        c("tallinn", "Tallinn", "Estonia", "Europe/Tallinn", 59.44, 24.75),
        c("riga", "Riga", "Latvia", "Europe/Riga", 56.95, 24.11),
        c("vilnius", "Vilnius", "Lithuania", "Europe/Vilnius", 54.69, 25.28),
        c("athens", "Athens", "Greece", "Europe/Athens", 37.98, 23.73),
        c("bucharest", "Bucharest", "Romania", "Europe/Bucharest", 44.43, 26.10),
        c("kyiv", "Kyiv", "Ukraine", "Europe/Kiev", 50.45, 30.52, ["Kiev"]),
        c("istanbul", "Istanbul", "Turkey", "Europe/Istanbul", 41.01, 28.98),
        c("moscow", "Moscow", "Russia", "Europe/Moscow", 55.76, 37.62),
        c("casablanca", "Casablanca", "Morocco", "Africa/Casablanca", 33.57, -7.59),
        c("lagos", "Lagos", "Nigeria", "Africa/Lagos", 6.52, 3.38),
        c("cairo", "Cairo", "Egypt", "Africa/Cairo", 30.04, 31.24),
        c("johannesburg", "Johannesburg", "South Africa", "Africa/Johannesburg", -26.20, 28.05),
        c("cape-town", "Cape Town", "South Africa", "Africa/Johannesburg", -33.92, 18.42),
        c("nairobi", "Nairobi", "Kenya", "Africa/Nairobi", -1.29, 36.82),
        c("addis-ababa", "Addis Ababa", "Ethiopia", "Africa/Addis_Ababa", 9.03, 38.74),
        c("jerusalem", "Jerusalem", "Israel", "Asia/Jerusalem", 31.77, 35.22, ["Tel Aviv"]),
        c("riyadh", "Riyadh", "Saudi Arabia", "Asia/Riyadh", 24.71, 46.68),
        c("dubai", "Dubai", "United Arab Emirates", "Asia/Dubai", 25.20, 55.27, ["UAE"]),
        c("tehran", "Tehran", "Iran", "Asia/Tehran", 35.69, 51.39),
        c("karachi", "Karachi", "Pakistan", "Asia/Karachi", 24.86, 67.01),
        c("tashkent", "Tashkent", "Uzbekistan", "Asia/Tashkent", 41.30, 69.24),
        c("mumbai", "Mumbai", "India", "Asia/Kolkata", 19.08, 72.88, ["Bombay"]),
        c("delhi", "Delhi", "India", "Asia/Kolkata", 28.61, 77.21, ["New Delhi"]),
        c("bengaluru", "Bengaluru", "India", "Asia/Kolkata", 12.97, 77.59, ["Bangalore"]),
        c("kathmandu", "Kathmandu", "Nepal", "Asia/Kathmandu", 27.72, 85.32),
        c("dhaka", "Dhaka", "Bangladesh", "Asia/Dhaka", 23.81, 90.41),
        c("almaty", "Almaty", "Kazakhstan", "Asia/Almaty", 43.24, 76.89),
        c("bangkok", "Bangkok", "Thailand", "Asia/Bangkok", 13.76, 100.50),
        c("ho-chi-minh", "Ho Chi Minh City", "Vietnam", "Asia/Ho_Chi_Minh", 10.82, 106.63, ["Saigon"]),
        c("jakarta", "Jakarta", "Indonesia", "Asia/Jakarta", -6.21, 106.85),
        c("singapore", "Singapore", "Singapore", "Asia/Singapore", 1.35, 103.82),
        c("kuala-lumpur", "Kuala Lumpur", "Malaysia", "Asia/Kuala_Lumpur", 3.14, 101.69),
        c("manila", "Manila", "Philippines", "Asia/Manila", 14.60, 120.98),
        c("hong-kong", "Hong Kong", "China", "Asia/Hong_Kong", 22.32, 114.17),
        c("shanghai", "Shanghai", "China", "Asia/Shanghai", 31.23, 121.47),
        c("beijing", "Beijing", "China", "Asia/Shanghai", 39.90, 116.41),
        c("taipei", "Taipei", "Taiwan", "Asia/Taipei", 25.03, 121.57),
        c("seoul", "Seoul", "South Korea", "Asia/Seoul", 37.57, 126.98),
        c("tokyo", "Tokyo", "Japan", "Asia/Tokyo", 35.68, 139.69),
        c("osaka", "Osaka", "Japan", "Asia/Tokyo", 34.69, 135.50),
        c("perth", "Perth", "Australia", "Australia/Perth", -31.95, 115.86),
        c("adelaide", "Adelaide", "Australia", "Australia/Adelaide", -34.93, 138.60),
        c("brisbane", "Brisbane", "Australia", "Australia/Brisbane", -27.47, 153.03),
        c("sydney", "Sydney", "Australia", "Australia/Sydney", -33.87, 151.21),
        c("melbourne", "Melbourne", "Australia", "Australia/Melbourne", -37.81, 144.96),
        c("auckland", "Auckland", "New Zealand", "Pacific/Auckland", -36.85, 174.76),
        c("fiji", "Suva", "Fiji", "Pacific/Fiji", -18.14, 178.44, ["Fiji"]),
        c("honolulu", "Honolulu", "United States", "Pacific/Honolulu", 21.31, -157.86, ["Hawaii"]),
        c("anchorage", "Anchorage", "United States", "America/Anchorage", 61.22, -149.90, ["Alaska"]),
        c("los-angeles", "Los Angeles", "United States", "America/Los_Angeles", 34.05, -118.24, ["LA"]),
        c("san-francisco", "San Francisco", "United States", "America/Los_Angeles", 37.77, -122.42, ["SF", "Bay Area"]),
        c("seattle", "Seattle", "United States", "America/Los_Angeles", 47.61, -122.33),
        c("vancouver", "Vancouver", "Canada", "America/Vancouver", 49.28, -123.12),
        c("phoenix", "Phoenix", "United States", "America/Phoenix", 33.45, -112.07),
        c("denver", "Denver", "United States", "America/Denver", 39.74, -104.99),
        c("chicago", "Chicago", "United States", "America/Chicago", 41.88, -87.63),
        c("austin", "Austin", "United States", "America/Chicago", 30.27, -97.74),
        c("mexico-city", "Mexico City", "Mexico", "America/Mexico_City", 19.43, -99.13),
        c("new-york", "New York", "United States", "America/New_York", 40.71, -74.01, ["NYC"]),
        c("boston", "Boston", "United States", "America/New_York", 42.36, -71.06),
        c("miami", "Miami", "United States", "America/New_York", 25.76, -80.19),
        c("toronto", "Toronto", "Canada", "America/Toronto", 43.65, -79.38),
        c("havana", "Havana", "Cuba", "America/Havana", 23.11, -82.37),
        c("bogota", "Bogota", "Colombia", "America/Bogota", 4.71, -74.07),
        c("lima", "Lima", "Peru", "America/Lima", -12.05, -77.04),
        c("caracas", "Caracas", "Venezuela", "America/Caracas", 10.48, -66.90),
        c("santiago", "Santiago", "Chile", "America/Santiago", -33.45, -70.67),
        c("halifax", "Halifax", "Canada", "America/Halifax", 44.65, -63.57),
        c("st-johns", "St. John's", "Canada", "America/St_Johns", 47.56, -52.71, ["Newfoundland"]),
        c("sao-paulo", "Sao Paulo", "Brazil", "America/Sao_Paulo", -23.55, -46.63),
        c("buenos-aires", "Buenos Aires", "Argentina", "America/Argentina/Buenos_Aires", -34.60, -58.38),
    ]
}
