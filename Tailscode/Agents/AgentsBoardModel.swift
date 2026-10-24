import TailscodeCore
import UIKit

enum AgentsSection: Hashable {
    case header
    case needsYou
    case working
    case background
    case finished

    var title: String? {
        switch self {
        case .header: return nil
        case .needsYou: return String(localized: "Needs you")
        case .working: return String(localized: "Working")
        case .background: return String(localized: "In the background")
        case .finished: return String(localized: "Finished")
        }
    }
}

enum AgentsItem: Hashable {
    case header
    case empty
    case ask(String)
    case row(String)
    case finish(String)
}

/// What an ask card's buttons are doing: a call out, a call that settled, or a call that failed
/// with the reason said in words. The card is only removed by the next publish, never by this.
enum AgentsActionState: Equatable {
    enum Kind: Equatable {
        case approve
        case deny
        case option(String)
    }

    case busy(Kind)
    case done(Kind)
    case failed(String)
}

/// Where a peek is aimed: one agent and what the board already knows of it, so the sheet has a
/// header the moment it opens and a listing to fall back on while nothing is watching it.
struct AgentsPeekTarget {
    let key: String
    let profileID: String
    let sessionID: String
    let title: String
    let machine: String
    let chip: ModelChip?
    var row: AgentRow?

    init(row: AgentRow) {
        key = row.id
        profileID = row.profileID
        sessionID = row.sessionID
        title = row.title
        machine = row.machine
        chip = row.chip
        self.row = row
    }

    init(ask card: AgentAskCard) {
        key = card.id
        profileID = card.profileID
        sessionID = card.sessionID
        title = card.title
        machine = card.machine
        chip = card.chip
        row = nil
    }

    init(lane: AgentHourLane, key: String) {
        self.key = key
        profileID = lane.profileID
        sessionID = lane.sessionID
        title = lane.title
        machine = lane.machine
        chip = nil
        row = nil
    }
}

extension AgentsItem {
    var key: String? {
        switch self {
        case .header, .empty: return nil
        case .ask(let id), .row(let id), .finish(let id): return id
        }
    }
}

extension AgentBoard {
    func row(_ id: String) -> AgentRow? {
        working.first { $0.id == id } ?? background.first { $0.id == id }
    }

    func ask(_ id: String) -> AgentAskCard? { needsYou.first { $0.id == id } }

    func finish(_ id: String) -> AgentFinish? { finished.first { $0.id == id } }
}

@MainActor
enum AgentsLayout {
    static let maxReadableWidth: CGFloat = 720

    static func isLarge(_ traits: UITraitCollection) -> Bool {
        traits.preferredContentSizeCategory.isAccessibilityCategory
    }

    static func trailing(_ view: UIView) -> NSTextAlignment {
        UIView.userInterfaceLayoutDirection(for: view.semanticContentAttribute) == .rightToLeft
            ? .left : .right
    }

    static func side(for width: CGFloat) -> CGFloat {
        max(Theme.Spacing.l, (width - maxReadableWidth) / 2)
    }
}
