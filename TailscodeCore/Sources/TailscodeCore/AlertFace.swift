import Foundation

/// One button a notification can carry, named by meaning so every client that can draw buttons
/// draws the same ones. `id` is what the tap reports back; the client maps it to its own
/// notification-action machinery.
public struct AlertAction: Sendable, Equatable {
    public let id: String
    public let title: String
    public let isDestructive: Bool

    public init(id: String, title: String, isDestructive: Bool) {
        self.id = id
        self.title = title
        self.isDestructive = isDestructive
    }
}

/// The kinds of notification the app raises, as categories a platform can register once and a
/// payload can name. A category owns its actions: an approval carries the two answers it is
/// waiting for, and everything else answers only to being opened.
public enum AlertCategory: String, Sendable, CaseIterable {
    case turn = "tailscode.turn"
    case turnFailed = "tailscode.turn.failed"
    case approval = "tailscode.approval"
    case question = "tailscode.question"
    case usage = "tailscode.usage"

    public static let approveActionID = "approve"
    public static let denyActionID = "deny"

    public var actions: [AlertAction] {
        switch self {
        case .approval:
            return [
                AlertAction(
                    id: Self.approveActionID, title: Localized.text("Approve"),
                    isDestructive: false),
                AlertAction(
                    id: Self.denyActionID, title: Localized.text("Deny"), isDestructive: true),
            ]
        case .turn, .turnFailed, .question, .usage:
            return []
        }
    }
}

/// What a notification wears, authored once beside the words it carries. The symbol is for the
/// Apple clients, the glyph for anywhere only text fits, the themed icon for the freedesktop
/// daemon, and the tone binds the face to the same four meanings every other badge answers to —
/// so the hand a chat's status badge raises is the hand the lock screen raises.
public struct AlertFace: Sendable, Equatable {
    public let symbol: String
    public let glyph: String
    public let tone: ActivityTone
    public let category: AlertCategory
    public let themedIcon: String

    public static let turnEnded = AlertFace(
        symbol: "checkmark.circle", glyph: "✓", tone: .live, category: .turn,
        themedIcon: "emblem-ok-symbolic")
    public static let turnFailed = AlertFace(
        symbol: "exclamationmark.triangle", glyph: "✗", tone: .danger, category: .turnFailed,
        themedIcon: "dialog-warning-symbolic")
    public static let needsApproval = AlertFace(
        symbol: "hand.raised", glyph: "⏸", tone: .attention, category: .approval,
        themedIcon: "dialog-question-symbolic")
    public static let needsAnswer = AlertFace(
        symbol: "questionmark.bubble", glyph: "?", tone: .attention, category: .question,
        themedIcon: "dialog-question-symbolic")
    public static let usage = AlertFace(
        symbol: "gauge.with.dots.needle.67percent", glyph: "◔", tone: .attention, category: .usage,
        themedIcon: "dialog-information-symbolic")
}

extension ActivityAlert.Reason {
    public var face: AlertFace {
        switch self {
        case .turnEnded: return .turnEnded
        case .turnFailed: return .turnFailed
        case .needsApproval: return .needsApproval
        case .needsAnswer: return .needsAnswer
        }
    }
}

extension MissedActivity.Reason {
    public var face: AlertFace {
        switch self {
        case .turnEnded: return .turnEnded
        case .turnFailed: return .turnFailed
        case .needsApproval: return .needsApproval
        case .needsAnswer: return .needsAnswer
        }
    }
}
