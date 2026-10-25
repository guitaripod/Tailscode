import Foundation

extension ShortcutRegistry {
    /// The ids a client that answers none of them drops from its bindings and its sheet.
    public static var appActionIDs: Set<String> { Set(appActions.map(\.id)) }

    /// The verbs that live in menus and header bars rather than in a pane: the windows the app
    /// opens, the switches a person flips between conversations, and the list's own numbering.
    /// Nearly all of them ship unbound — they exist so a person who wants a key for one has a
    /// place to put it, and so an upgrade never takes a key someone already uses.
    static let appActions: [ShortcutDefinition] =
        [
            .init(
                id: "app.settings", title: Localized.text("Open Settings"), category: .app,
                action: .openSettings, contexts: [.normal, .insert, .terminal],
                defaults: ["ctrl+comma"]),
            .init(
                id: "app.servers", title: Localized.text("Open your machines"), category: .app,
                action: .openServers, contexts: [.normal], defaults: []),
            .init(
                id: "app.updates", title: Localized.text("Open the Update Center"),
                category: .app, action: .openUpdates, contexts: [.normal], defaults: []),
            .init(
                id: "app.usage", title: Localized.text("Open usage and quota"), category: .app,
                action: .openUsage, contexts: [.normal], defaults: []),
            .init(
                id: "app.appearance", title: Localized.text("Switch between light and dark"),
                category: .app, action: .toggleAppearance,
                contexts: [.normal, .insert, .terminal], defaults: []),
            .init(
                id: "app.fullscreen", title: Localized.text("Full screen"), category: .app,
                action: .toggleFullscreen, contexts: [.normal, .insert, .terminal],
                defaults: ["f11"]),
            .init(
                id: "composer.compactTools",
                title: Localized.text("Fold or open the agent's steps"),
                category: .conversation, action: .toggleCompactTools, contexts: [.normal],
                defaults: []),
            .init(
                id: "composer.vimMode", title: Localized.text("Vim mode in the prompt box"),
                category: .composer, action: .toggleVimComposer, contexts: [.normal],
                defaults: []),
        ]
        + (1...9).map { number in
            ShortcutDefinition(
                id: "chat.open\(number)",
                title: Localized.text("Open chat %d in the list", number), category: .chats,
                action: .openChat(number), contexts: [.normal, .insert], defaults: [])
        }
}
