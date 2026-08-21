import Foundation

/// What to say when Apple's account system will not answer.
///
/// GameKit reports its refusals as `NSError`, and an error's `localizedDescription` is written for
/// a console rather than for a person reading their own month: "The requested operation could not
/// be completed because local player has not been authenticated" is true, unhelpful, and the sort
/// of sentence a surface should never be caught wearing. The trophy case renders whole without an
/// account, so the line beside it is a state, not a failure — and like every other state in this
/// app the words are Core's, so both Apple clients say the same thing.
public enum GameCenterReading: Sendable, Equatable {
    /// Nobody is signed in on this device. The commonest case by far, and not a problem.
    case signedOut
    /// Signed in, but this build cannot ask — the entitlement is not in it.
    case notEntitled
    /// Game Center is switched off for this account, by Screen Time or by an administrator.
    case restricted
    /// Something else. The reason is kept for the log, never for the screen.
    case refused

    /// - Parameters:
    ///   - domain: the error's domain, or nil when GameKit simply reported no player.
    ///   - code: the error's code.
    ///   - description: the error's own words, used only to recognise the entitlement refusal that
    ///     GameKit reports with no distinguishing code of its own.
    public static func read(domain: String?, code: Int, description: String) -> GameCenterReading {
        let lowered = description.lowercased()
        if lowered.contains("entitlement") { return .notEntitled }
        guard domain == "GKErrorDomain" else { return description.isEmpty ? .signedOut : .refused }
        switch code {
        case 2, 6: return .signedOut
        case 7: return .restricted
        default: return .refused
        }
    }

    /// One sentence, and never a rule or an error code: what is true, and what would change it.
    public var line: String {
        switch self {
        case .signedOut:
            return Localized.text(
                "Not signed in to Game Center, so nothing is reported to Apple — the trophies below are counted on this device either way.")
        case .notEntitled:
            return Localized.text(
                "This copy of the app cannot sign in to Game Center, so the trophies below are counted on this device and go no further.")
        case .restricted:
            return Localized.text(
                "Game Center is turned off for this account, so the trophies below are counted on this device and go no further.")
        case .refused:
            return Localized.text(
                "Game Center is not answering, so the trophies below are counted on this device until it does.")
        }
    }
}
