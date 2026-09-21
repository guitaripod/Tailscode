import Foundation

/// How long a render takes on the machine that renders, learned from the ones already made.
///
/// A clip costs pixels times frames, and the card works through them at a rate that is the
/// machine's and the model's rather than the clip's — so one number per model is kept, seconds
/// per megapixel-frame, moved toward each finished render, and the next recipe is priced from it.
/// The figure is always said as "about": a cold card loads forty gigabytes before the first step
/// and a queue ahead is somebody else's time, and neither is this clip's to promise.
public struct ForgeClock: Sendable, Codable, Equatable {
    struct Rate: Sendable, Codable, Equatable {
        var secondsPerUnit: Double
        var samples: Int
    }

    private var rates: [String: Rate]

    public init() {
        rates = [:]
    }

    /// How far a new reading moves the rate. Half, so a morning that woke the card cold is
    /// forgotten after a couple of clips rather than remembered all week.
    static let blend = 0.5

    /// Whether anything has been learned yet for the model this recipe uses.
    public func knows(_ recipe: ForgeRecipe) -> Bool {
        rates[Self.key(for: recipe)] != nil
    }

    /// Seconds this recipe is expected to take, or nil until a clip on the same model has
    /// finished and been measured.
    public func estimate(_ recipe: ForgeRecipe) -> TimeInterval? {
        guard let rate = rates[Self.key(for: recipe)] else { return nil }
        return rate.secondsPerUnit * Self.work(recipe)
    }

    /// Learns from one finished render: the recipe and the seconds the machine spent on it.
    public mutating func learn(_ recipe: ForgeRecipe, seconds: TimeInterval) {
        let units = Self.work(recipe)
        guard seconds > 0, units > 0 else { return }
        let observed = seconds / units
        let key = Self.key(for: recipe)
        if let held = rates[key] {
            let blended = held.secondsPerUnit + (observed - held.secondsPerUnit) * Self.blend
            rates[key] = Rate(secondsPerUnit: blended, samples: held.samples + 1)
        } else {
            rates[key] = Rate(secondsPerUnit: observed, samples: 1)
        }
    }

    /// Pixels times frames, in millions. The unit the rate is kept in.
    static func work(_ recipe: ForgeRecipe) -> Double {
        Double(recipe.width) * Double(recipe.height) * Double(recipe.length) / 1_000_000
    }

    /// One rate per model. A clip that opens on a picture costs the same sampling as one that
    /// does not, so the frame is not part of the key.
    static func key(for recipe: ForgeRecipe) -> String {
        recipe.model.rawValue
    }

    /// Seconds as a person would say them: under a minute in seconds, otherwise minutes with the
    /// seconds only while there are fewer than ten minutes.
    public static func words(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        if whole < 60 { return Localized.text("%@ s", "\(max(whole, 1))") }
        let minutes = whole / 60
        let rest = whole % 60
        if minutes >= 10 || rest == 0 { return Localized.text("%@ min", "\(minutes)") }
        return Localized.text("%@ min %@ s", "\(minutes)", "\(rest)")
    }

    /// The line under a draft: what the render should cost before it is pressed.
    public static func aboutLine(_ seconds: TimeInterval) -> String {
        Localized.text("about %@", words(seconds))
    }

    /// The line beside a bar: how much longer, from the estimate and the clock.
    public static func leftLine(_ seconds: TimeInterval) -> String {
        Localized.text("about %@ left", words(seconds))
    }
}
