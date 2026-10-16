import Foundation

/// When the sun is up at one place on one local day.
public struct SolarDay: Sendable, Equatable {
    public enum Sky: Sendable, Equatable {
        case rises(sunrise: Date, sunset: Date)
        case alwaysUp
        case neverUp
    }

    public let sky: Sky
    public let solarNoon: Date
}

/// Sunrise and sunset from latitude, longitude and a date: the sunrise equation, good to a few
/// minutes, which is far finer than a strip the width of a popover can show. Nothing here asks a
/// network or an almanac, so the strip is right offline and in a year nobody has published yet.
public enum Solar {
    private static let horizon = -0.833

    public static func day(
        latitude: Double, longitude: Double, containing instant: Date, in zone: TimeZone
    ) -> SolarDay {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let start = calendar.startOfDay(for: instant)
        let noon = calendar.date(byAdding: .hour, value: 12, to: start)
            ?? start.addingTimeInterval(43_200)
        let julianNoon = noon.timeIntervalSince1970 / 86_400 + 2_440_587.5
        let n = (julianNoon - 2_451_545.0 + 0.0008 + longitude / 360).rounded()
        let mean = n - longitude / 360
        let anomaly = radians(wrapped(357.5291 + 0.98560028 * mean))
        let center =
            1.9148 * sin(anomaly) + 0.02 * sin(2 * anomaly) + 0.0003 * sin(3 * anomaly)
        let eclipticLongitude = radians(wrapped(degrees(anomaly) + center + 180 + 102.9372))
        let transit =
            2_451_545.0 + mean + 0.0053 * sin(anomaly) - 0.0069 * sin(2 * eclipticLongitude)
        let declination = asin(sin(eclipticLongitude) * sin(radians(23.4397)))
        let phi = radians(max(-89.9, min(89.9, latitude)))
        let cosHour =
            (sin(radians(horizon)) - sin(phi) * sin(declination)) / (cos(phi) * cos(declination))
        let solarNoon = date(fromJulian: transit)
        if cosHour > 1 { return SolarDay(sky: .neverUp, solarNoon: solarNoon) }
        if cosHour < -1 { return SolarDay(sky: .alwaysUp, solarNoon: solarNoon) }
        let hourAngle = degrees(acos(cosHour))
        return SolarDay(
            sky: .rises(
                sunrise: date(fromJulian: transit - hourAngle / 360),
                sunset: date(fromJulian: transit + hourAngle / 360)),
            solarNoon: solarNoon)
    }

    private static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
    private static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }

    private static func wrapped(_ degrees: Double) -> Double {
        let remainder = degrees.truncatingRemainder(dividingBy: 360)
        return remainder < 0 ? remainder + 360 : remainder
    }

    private static func date(fromJulian julian: Double) -> Date {
        Date(timeIntervalSince1970: (julian - 2_440_587.5) * 86_400)
    }
}

/// One local day of a zone, laid out as a line: the instants it starts and ends at, and the
/// position of any instant along it. It is the axis every strip and lane is drawn on, so a strip
/// that spans a daylight-saving change is 23 or 25 hours long rather than wrong by one.
public struct DayAxis: Sendable, Equatable {
    public let zone: TimeZone
    public let start: Date
    public let end: Date

    public init(zone: TimeZone, containing instant: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let start = calendar.startOfDay(for: instant)
        self.zone = zone
        self.start = start
        self.end = calendar.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(86_400)
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    public var minutes: Int { max(1, Int((duration / 60).rounded())) }

    public func fraction(of instant: Date) -> Double {
        instant.timeIntervalSince(start) / duration
    }

    public func instant(atMinute minute: Int) -> Date {
        start.addingTimeInterval(Double(min(max(minute, 0), minutes - 1)) * 60)
    }

    public func minute(of instant: Date) -> Int {
        min(max(Int((instant.timeIntervalSince(start) / 60).rounded(.down)), 0), minutes - 1)
    }

    public func contains(_ instant: Date) -> Bool { instant >= start && instant < end }
}

public struct DaylightStop: Sendable, Equatable {
    public let position: Double
    public let light: Double
}

/// The day of one city drawn along an axis: a gradient from night (0) to day (1) with the
/// twilight ramps in it, and where the sun stands at noon. A client mixes two colours by `light`
/// and decides nothing else.
public struct DaylightBar: Sendable, Equatable {
    public let stops: [DaylightStop]
    public let noon: Double?
    public let hasSun: Bool

    public static let flat = DaylightBar(
        stops: [DaylightStop(position: 0, light: 0.35), DaylightStop(position: 1, light: 0.35)],
        noon: nil, hasSun: false)

    public func light(at fraction: Double) -> Double {
        guard let first = stops.first, let last = stops.last else { return 0 }
        if fraction <= first.position { return first.light }
        if fraction >= last.position { return last.light }
        for (lower, upper) in zip(stops, stops.dropFirst()) where fraction <= upper.position {
            let span = upper.position - lower.position
            guard span > 0 else { return upper.light }
            return lower.light + (upper.light - lower.light) * (fraction - lower.position) / span
        }
        return last.light
    }

    public func isUp(at fraction: Double) -> Bool { hasSun && light(at: fraction) >= 0.5 }
}

public enum Daylight {
    /// Half the width of a twilight ramp, in seconds. Civil twilight runs about half an hour either
    /// side of the horizon at mid latitudes, and a ramp that wide reads as dusk rather than a seam.
    public static let twilightHalf: TimeInterval = 1_800

    public static func bar(for city: WorldCity, on axis: DayAxis) -> DaylightBar {
        guard let latitude = city.latitude, let longitude = city.longitude,
            let zone = city.timeZone
        else { return .flat }
        var ups: [(Double, Double)] = []
        var noon: Double?
        var seen: Set<Int> = []
        for hours in [-36.0, -12, 12, 36, 60] {
            let probe = axis.start.addingTimeInterval(hours * 3600)
            let day = Solar.day(
                latitude: latitude, longitude: longitude, containing: probe, in: zone)
            guard seen.insert(Int(day.solarNoon.timeIntervalSince1970 / 60)).inserted else {
                continue
            }
            let position = axis.fraction(of: day.solarNoon)
            switch day.sky {
            case .rises(let sunrise, let sunset):
                ups.append((axis.fraction(of: sunrise), axis.fraction(of: sunset)))
                if noon == nil, (0...1).contains(position) { noon = position }
            case .alwaysUp:
                ups.append((-10, 10))
                if noon == nil, (0...1).contains(position) { noon = position }
            case .neverUp:
                break
            }
        }
        let width = twilightHalf / axis.duration
        return DaylightBar(stops: stops(from: ups, width: width), noon: noon, hasSun: true)
    }

    private static func stops(from intervals: [(Double, Double)], width: Double)
        -> [DaylightStop]
    {
        let merged = merge(intervals, gap: 2 * width)
        func light(_ x: Double) -> Double {
            var best = 0.0
            for (lower, upper) in merged {
                let rise = clamp((x - (lower - width)) / (2 * width))
                let fall = clamp(((upper + width) - x) / (2 * width))
                best = max(best, min(rise, fall))
            }
            return best
        }
        var positions: Set<Double> = [0, 1]
        for (lower, upper) in merged {
            for candidate in [lower - width, lower + width, upper - width, upper + width]
            where candidate > 0 && candidate < 1 {
                positions.insert(candidate)
            }
        }
        return positions.sorted().map { DaylightStop(position: $0, light: light($0)) }
    }

    private static func merge(_ intervals: [(Double, Double)], gap: Double) -> [(Double, Double)] {
        var merged: [(Double, Double)] = []
        for interval in intervals.sorted(by: { $0.0 < $1.0 }) {
            if let last = merged.last, interval.0 - last.1 <= gap {
                merged[merged.count - 1] = (last.0, max(last.1, interval.1))
            } else {
                merged.append(interval)
            }
        }
        return merged
    }

    private static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
}

/// The hours a person is taken to be awake, and the arithmetic of where several people's hours
/// meet. It is a convention and not a fact about anyone — seven to eleven — which is why the
/// sentence built from it says *awake* only where it means that and never *available*.
public enum Awake {
    public static let wakes = 7
    public static let sleeps = 23

    public static func intervals(in zone: TimeZone, within axis: DayAxis) -> [DateInterval] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        var result: [DateInterval] = []
        var seen: Set<Date> = []
        for hours in [-36.0, -12, 12, 36, 60] {
            let day = calendar.startOfDay(for: axis.start.addingTimeInterval(hours * 3600))
            guard seen.insert(day).inserted,
                let open = calendar.date(bySettingHour: wakes, minute: 0, second: 0, of: day),
                let close = calendar.date(bySettingHour: sleeps, minute: 0, second: 0, of: day)
            else { continue }
            let lower = max(open, axis.start)
            let upper = min(close, axis.end)
            if upper > lower { result.append(DateInterval(start: lower, end: upper)) }
        }
        return result.sorted { $0.start < $1.start }
    }

    public static func overlap(_ lhs: [DateInterval], _ rhs: [DateInterval]) -> [DateInterval] {
        var result: [DateInterval] = []
        for left in lhs {
            for right in rhs {
                let lower = max(left.start, right.start)
                let upper = min(left.end, right.end)
                if upper > lower { result.append(DateInterval(start: lower, end: upper)) }
            }
        }
        return result.sorted { $0.start < $1.start }
    }
}
