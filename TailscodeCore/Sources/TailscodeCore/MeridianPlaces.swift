import Foundation

/// One city as the place-adding surface shows it: who it is, what time it is there right now,
/// and how far that is from here, so a person picks a place by its clock and not by guessing at
/// its zone.
public struct PlaceRow: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let country: String
    public let detail: String
    public let time: String
    public let offset: String
    public let dayWord: String

    public var spoken: String {
        String(format: Localized.text("%@, %@, %@"), name, time, offset)
    }
}

/// How full the list of places is and what the surface should say about it.
public struct PlacesStatus: Sendable, Equatable {
    public let count: Int
    public let limit: Int

    public var isFull: Bool { count >= limit }

    public var summary: String {
        String(format: Localized.text("%d of %d places"), count, limit)
    }

    public var invitation: String {
        isFull
            ? Localized.text("Remove a place to add another") : Localized.text("Add a place")
    }

    public var placeholder: String {
        isFull
            ? Localized.text("Remove a place to add another")
            : Localized.text("Search a city or country")
    }
}

/// Everything the Add-a-place surface needs, so both desktops list, suggest and describe places
/// in the same words: matches while typing, the places most people reach for when nothing has
/// been typed, and how many of the eight the list already holds.
public enum MeridianPlaces {
    public static func results(
        for query: String, preferences: WorldClockPreferences, viewer: TimeZone, now: Date,
        limit: Int = 6
    ) -> [PlaceRow] {
        let here = WorldCities.displayName(forZone: viewer.identifier)
        return WorldCities.search(query, excluding: Set(preferences.pins), limit: limit + 1)
            .filter { $0.name != here }
            .prefix(limit)
            .map { row(for: $0, preferences: preferences, viewer: viewer, now: now) }
    }

    public static func suggestions(
        preferences: WorldClockPreferences, viewer: TimeZone, now: Date, limit: Int = 6
    ) -> [PlaceRow] {
        let pinned = Set(preferences.pins)
        return WorldCities.popularIDs
            .compactMap(WorldCities.city)
            .filter { !pinned.contains($0.id) && $0.zoneID != viewer.identifier }
            .prefix(limit)
            .map { row(for: $0, preferences: preferences, viewer: viewer, now: now) }
    }

    public static func status(_ preferences: WorldClockPreferences) -> PlacesStatus {
        PlacesStatus(count: preferences.pins.count, limit: WorldClockPreferences.maxPins)
    }

    public static func emptyResult(for query: String) -> String {
        String(format: Localized.text("No place matches “%@”"), query)
    }

    private static func row(
        for city: WorldCity, preferences: WorldClockPreferences, viewer: TimeZone, now: Date
    ) -> PlaceRow {
        let zone = city.timeZone ?? .gmt
        let delta = zone.secondsFromGMT(for: now) - viewer.secondsFromGMT(for: now)
        let country = city.country.isEmpty ? Localized.text("Universal time") : city.country
        return PlaceRow(
            id: city.id, name: city.name, country: country,
            detail: "\(country) \u{00B7} \(ClockFormat.utc(zone.secondsFromGMT(for: now)))",
            time: ClockFormat.time(now, in: zone, style: preferences.style),
            offset: ClockFormat.offset(delta),
            dayWord: ClockFormat.dayWord(now, in: zone, relativeTo: viewer))
    }
}

extension ClockStyle {
    /// The same moment written the way this choice would write it, so a control can show what
    /// each option does instead of naming it.
    public func example(at instant: Date, in zone: TimeZone) -> String {
        ClockFormat.time(instant, in: zone, style: self)
    }

    /// What *Follow system* currently follows, in words, because "system" alone says nothing
    /// about what the clock will read.
    public static func systemDescription() -> String {
        ClockStyle.system.is24Hour ? ClockStyle.h24.title : ClockStyle.h12.title
    }
}
