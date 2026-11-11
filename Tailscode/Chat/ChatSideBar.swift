import UIKit

/// What a conversation keeps under the thumb while the system draws its bars down a side edge.
///
/// The top of that bar says where the reader is — back, the column toggle, the call and the
/// overflow — and the foot is what the reader does over and over in this conversation: find,
/// back up a turn, the agents board and the next chat, with a way to put the keyboard away while
/// it is up. Every item at the foot acts on one press and none opens a menu: a menu takes the
/// keyboard focus the chat holds for hardware keys, the system raises a keyboard for it, and the
/// shortened bar drops the very button the menu hangs from.
/// A horizontal bar keeps the layout every other iPhone has, so none of this shows without one:
/// there find is in the overflow menu, and the board and the next chat are on Home.
@MainActor
final class ChatSideBar {
    struct Actions {
        let find: @MainActor () -> Void
        let previousPrompt: @MainActor () -> Void
        let agents: @MainActor () -> Void
        let newChat: @MainActor () -> Void
        let hideKeyboard: @MainActor () -> Void
    }

    private(set) var isVertical = false
    var keyboardShown = false

    private let find: UIBarButtonItem
    private let previousPrompt: UIBarButtonItem
    private let agents: UIBarButtonItem
    private let newChat: UIBarButtonItem
    private let hideKeyboard: UIBarButtonItem
    private let readingGap = UIBarButtonItem.flexibleSpace()
    private let keyboardGap = UIBarButtonItem.flexibleSpace()

    init(actions: Actions) {
        find = UIBarButtonItem(
            primaryAction: UIAction(
                title: String(localized: "Find"), image: UIImage(systemName: "magnifyingglass")
            ) { _ in actions.find() })
        previousPrompt = UIBarButtonItem(
            primaryAction: UIAction(
                title: String(localized: "Previous prompt"),
                image: UIImage(systemName: "arrow.up.to.line")
            ) { _ in actions.previousPrompt() })
        agents = UIBarButtonItem(
            primaryAction: UIAction(
                title: String(localized: "Agents"), image: UIImage(systemName: "person.2")
            ) { _ in actions.agents() })
        newChat = UIBarButtonItem(
            primaryAction: UIAction(
                title: String(localized: "New chat"), image: UIImage(systemName: "square.and.pencil")
            ) { _ in actions.newChat() })
        hideKeyboard = UIBarButtonItem(
            primaryAction: UIAction(
                title: String(localized: "Hide keyboard"),
                image: UIImage(systemName: "keyboard.chevron.compact.down")
            ) { _ in actions.hideKeyboard() })
        VerticalBar.rank(find, .standard)
        VerticalBar.rank(previousPrompt, .first)
        VerticalBar.rank(agents, .standard)
        VerticalBar.rank(newChat, .keep)
        VerticalBar.rank(hideKeyboard, .keep)
    }

    /// Takes in the traits the screen now has and says whether its bar changed axis.
    func read(_ traits: UITraitCollection) -> Bool {
        let vertical = VerticalBar.isPresent(in: traits)
        guard vertical != isVertical else { return false }
        isVertical = vertical
        return true
    }

    /// The foot of the bar, in the groups it is drawn in; empty while the bar is horizontal.
    /// `startsChats` is false where this screen has no Home to start the next chat from.
    /// Above the keyboard the bar has room for little, and the way out of typing outranks the
    /// next chat, which waits in the overflow until the keyboard goes.
    func toolbarItems(startsChats: Bool) -> [UIBarButtonItem] {
        guard isVertical else { return [] }
        VerticalBar.rank(newChat, keyboardShown ? .standard : .keep)
        var items: [UIBarButtonItem] = [find, previousPrompt, readingGap, agents]
        if startsChats { items.append(newChat) }
        if keyboardShown { items += [keyboardGap, hideKeyboard] }
        return items
    }
}
