import UserNotifications

#if !NOTICE_EXTENSION
    import TailscodeCore
#endif

/// The buttons a notification carries, named by what they do so the app that handles them and the
/// extensions that register them agree on the words.
enum NoticeActionID {
    static let approve = "approve"
    static let deny = "deny"
    static let reply = "reply"
    static let retry = "retry"
    static let answer = "answer"
    static let choicePrefix = "choice:"

    static func choice(_ index: Int) -> String { "\(choicePrefix)\(index)" }

    /// The category of a notice that has nothing to be done with: no chat to reply to, no request
    /// to answer. Buttons that cannot act are worse than none.
    static let plainCategory = "tailscode.plain"

    static func choiceIndex(_ identifier: String) -> Int? {
        guard identifier.hasPrefix(choicePrefix) else { return nil }
        return Int(identifier.dropFirst(choicePrefix.count))
    }
}

/// Which pending question owns which of a few question categories.
///
/// A category's buttons are fixed when it is registered, and a question's buttons are its own
/// options, so a question that offers options takes a slot, registers that slot's category with
/// its options, and is dressed in it. When every slot is taken the oldest loses its notice rather
/// than keep buttons that now say something else: a button that answers a different question than
/// it is labelled with is worse than a notice that is gone. The table lives in the app group
/// because the notification service claims slots for pushes as the app does for its own notices.
enum NoticeSlots {
    static let count = 4
    static let groupSuite = "group.com.guitaripod.tailscode"
    private static let key = "tailscode.notice.slots"

    struct Entry: Codable, Equatable {
        var identifier: String
        var choices: [String]
        var free: Bool
        var claimedAt: Date
    }

    static func categoryID(slot: Int) -> String { "tailscode.question.slot\(slot)" }

    private static var store: UserDefaults {
        UserDefaults(suiteName: groupSuite) ?? .standard
    }

    static func entries() -> [Entry?] {
        guard let data = store.data(forKey: key),
            let stored = try? JSONDecoder().decode([Entry?].self, from: data)
        else { return Array(repeating: nil, count: count) }
        return stored + Array(repeating: nil, count: max(0, count - stored.count))
    }

    private static func save(_ entries: [Entry?]) {
        if let data = try? JSONEncoder().encode(entries) { store.set(data, forKey: key) }
    }

    /// The slot for a question, and the identifier of the notice it displaced, if any. A question
    /// that already holds a slot keeps it.
    static func claim(
        identifier: String, choices: [String], free: Bool, now: Date = Date()
    ) -> (slot: Int, evicted: String?) {
        var table = entries()
        let entry = Entry(identifier: identifier, choices: choices, free: free, claimedAt: now)
        if let held = table.firstIndex(where: { $0?.identifier == identifier }) {
            table[held] = entry
            save(table)
            return (held, nil)
        }
        if let empty = table.firstIndex(where: { $0 == nil }) {
            table[empty] = entry
            save(table)
            return (empty, nil)
        }
        let oldest = table.indices.min { (table[$0]?.claimedAt ?? .distantPast) < (table[$1]?.claimedAt ?? .distantPast) } ?? 0
        let evicted = table[oldest]?.identifier
        table[oldest] = entry
        save(table)
        return (oldest, evicted)
    }

    static func release(identifier: String) {
        var table = entries()
        guard let held = table.firstIndex(where: { $0?.identifier == identifier }) else { return }
        table[held] = nil
        save(table)
    }
}

/// Every category the app's notifications can wear, registered together because the system keeps
/// exactly the set it was last given.
enum NoticeCategories {
    static func all() -> Set<UNNotificationCategory> {
        var categories: [UNNotificationCategory] = [
            make(.done, [textAction(NoticeActionID.reply, symbol: "arrowshape.turn.up.left.fill")]),
            make(
                .failed,
                [
                    action(NoticeActionID.retry, Localized.text("Try again"), symbol: "arrow.clockwise"),
                    textAction(NoticeActionID.reply, symbol: "arrowshape.turn.up.left.fill"),
                ]),
            make(
                .approval,
                [
                    action(
                        NoticeActionID.approve, Localized.text("Approve"),
                        symbol: "checkmark.circle.fill", options: [.authenticationRequired]),
                    action(
                        NoticeActionID.deny, Localized.text("Deny"), symbol: "xmark.circle.fill",
                        options: [.destructive]),
                ]),
            make(.question, [answerAction()]),
            make(.usage, []),
            UNNotificationCategory(
                identifier: NoticeActionID.plainCategory, actions: [], intentIdentifiers: [],
                options: []),
        ]
        let table = NoticeSlots.entries()
        for slot in 0..<NoticeSlots.count {
            categories.append(slotCategory(slot, table[slot]))
        }
        return Set(categories)
    }

    static func register() {
        UNUserNotificationCenter.current().setNotificationCategories(all())
    }

    /// A question that offers options gets its own category, so the options are its buttons.
    /// Returns the category to dress the notice in and the identifier of a notice that lost its
    /// slot to it, which the caller withdraws.
    static func claimSlot(
        identifier: String, reading: NoticeReading
    ) -> (category: String, evicted: String?)? {
        guard !reading.choices.isEmpty else { return nil }
        let claim = NoticeSlots.claim(
            identifier: identifier, choices: reading.choices,
            free: reading.replyPlaceholder != nil)
        register()
        return (NoticeSlots.categoryID(slot: claim.slot), claim.evicted)
    }

    private static func slotCategory(_ slot: Int, _ entry: NoticeSlots.Entry?) -> UNNotificationCategory {
        var actions: [UNNotificationAction] = []
        for (index, label) in (entry?.choices ?? []).enumerated() {
            actions.append(
                action(NoticeActionID.choice(index), label, symbol: "\(index + 1).circle"))
        }
        if entry?.free ?? true { actions.append(answerAction(title: Localized.text("Other…"))) }
        return UNNotificationCategory(
            identifier: NoticeSlots.categoryID(slot: slot), actions: actions, intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: NoticePresentation.of(.question).hiddenBody,
            categorySummaryFormat: Localized.text("%u more updates in %@"), options: [])
    }

    private static func make(_ kind: NoticeWire.Kind, _ actions: [UNNotificationAction])
        -> UNNotificationCategory
    {
        let presentation = NoticePresentation.of(kind)
        return UNNotificationCategory(
            identifier: presentation.category, actions: actions, intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: presentation.hiddenBody,
            categorySummaryFormat: Localized.text("%u more updates in %@"), options: [])
    }

    private static func action(
        _ id: String, _ title: String, symbol: String, options: UNNotificationActionOptions = []
    ) -> UNNotificationAction {
        UNNotificationAction(
            identifier: id, title: title, options: options,
            icon: UNNotificationActionIcon(systemImageName: symbol))
    }

    private static func textAction(_ id: String, symbol: String) -> UNNotificationAction {
        UNTextInputNotificationAction(
            identifier: id, title: Localized.text("Reply"), options: [],
            icon: UNNotificationActionIcon(systemImageName: symbol),
            textInputButtonTitle: Localized.text("Send"),
            textInputPlaceholder: Localized.text("Message your agent…"))
    }

    private static func answerAction(title: String? = nil) -> UNNotificationAction {
        UNTextInputNotificationAction(
            identifier: NoticeActionID.answer, title: title ?? Localized.text("Answer"),
            options: [], icon: UNNotificationActionIcon(systemImageName: "text.bubble.fill"),
            textInputButtonTitle: Localized.text("Send"),
            textInputPlaceholder: Localized.text("Your answer"))
    }
}
