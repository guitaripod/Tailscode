import UIKit

extension ChatViewController {
    func makeSideBar() -> ChatSideBar {
        ChatSideBar(
            actions: .init(
                find: { [weak self] in self?.openFind() },
                previousPrompt: { [weak self] in _ = self?.performKeyAction(.previousPrompt) },
                agents: { [weak self] in
                    guard let self else { return }
                    AgentsPresenter.toggle(from: self)
                },
                newChat: { [weak self] in self?.startNextChatHere() },
                hideKeyboard: { [weak self] in self?.view.endEditing(true) }))
    }

    func watchSideBar() {
        VerticalBar.observe(self) { chat in chat.refreshSideBar() }
        for name in [UITextField.textDidBeginEditingNotification, UITextView.textDidBeginEditingNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(sideBarTypingBegan), name: name, object: nil)
        }
        for name in [UITextField.textDidEndEditingNotification, UITextView.textDidEndEditingNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(sideBarTypingEnded), name: name, object: nil)
        }
    }

    func refreshSideBar() {
        guard sideBar.read(traitCollection) else { return }
        applyBarItems()
    }

    /// Hands every bar item to the bar the system is drawing now: the overflow and the call in the
    /// navigation bar either way, and the conversation's own actions at the foot of a side bar,
    /// where the overflow becomes the bar's own so one `…` holds both the rare actions and
    /// whatever the bar has no room for.
    func applyBarItems() {
        let vertical = sideBar.isVertical
        let right = vertical ? callController.barItems : (overflowItem.map { [$0] } ?? []) + callController.barItems
        if navigationItem.rightBarButtonItems ?? [] != right { navigationItem.rightBarButtonItems = right }
        let overflow = vertical ? sideOverflow : nil
        if navigationItem.additionalOverflowItems !== overflow { navigationItem.additionalOverflowItems = overflow }
        setToolbarItemsIfChanged(sideBar.toolbarItems(startsChats: startsChatsFromHere))
        syncSideBarToolbar(animated: false)
    }

    func makeSideOverflow() -> UIDeferredMenuElement {
        UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.overflowMenuChildren(sideBarHoldsFind: true) ?? [])
        }
    }

    private func setToolbarItemsIfChanged(_ items: [UIBarButtonItem]) {
        let wanted = items.isEmpty ? nil : items
        guard toolbarItems != wanted else { return }
        toolbarItems = wanted
    }

    /// Shows the stack's toolbar while this conversation is on top and its bar runs down a side,
    /// and never otherwise: without a side bar the same items would be a strip under the composer.
    func syncSideBarToolbar(animated: Bool) {
        guard let navigationController, navigationController.topViewController === self else { return }
        let hidden = !sideBar.isVertical
        guard navigationController.isToolbarHidden != hidden else { return }
        navigationController.setToolbarHidden(hidden, animated: animated)
    }

    /// Puts the toolbar away as the conversation leaves, unless what replaces it is another
    /// conversation, which shows its own.
    func releaseSideBarToolbar(animated: Bool) {
        guard let navigationController, !navigationController.isToolbarHidden,
            !(navigationController.topViewController is ChatViewController)
        else { return }
        navigationController.setToolbarHidden(true, animated: animated)
    }

    /// Where a sheet that would hang off the overflow button hangs from when that button is the
    /// side bar's own and has no item to point at: the bar's edge, under the title.
    func anchorToOverflow(_ popover: UIPopoverPresentationController?) {
        guard let popover else { return }
        if !sideBar.isVertical, let overflowItem {
            popover.barButtonItem = overflowItem
            return
        }
        let insets = view.safeAreaInsets
        let x = insets.right >= insets.left ? view.bounds.maxX - insets.right / 2 : insets.left / 2
        popover.sourceView = view
        popover.sourceRect = CGRect(x: x, y: insets.top + 44, width: 1, height: 1)
    }

    private var startsChatsFromHere: Bool {
        splitViewController is WorkspaceSplitViewController
    }

    /// The next chat starts where every chat starts, in Home's composer, already aimed at the
    /// machine and folder of the one being read, so a press here is "another one like this".
    private func startNextChatHere() {
        guard let split = splitViewController as? WorkspaceSplitViewController else { return }
        split.startNewChat(profileID: viewModel.contextID, directory: viewModel.session.directory)
    }

    /// Typing counts only in this screen's own fields — the composer, find, an answer. A long menu
    /// raises a keyboard of its own to filter by, and rebuilding the bar for that would close the
    /// very menu it serves.
    @objc private func sideBarTypingBegan(_ note: Notification) {
        guard let field = note.object as? UIView, field.isDescendant(of: view) else { return }
        setSideBarKeyboard(shown: true)
    }

    @objc private func sideBarTypingEnded(_ note: Notification) {
        guard let field = note.object as? UIView, field.isDescendant(of: view) else { return }
        setSideBarKeyboard(shown: false)
    }

    private func setSideBarKeyboard(shown: Bool) {
        guard sideBar.keyboardShown != shown else { return }
        sideBar.keyboardShown = shown
        guard sideBar.isVertical, viewIfLoaded?.window != nil else { return }
        setToolbarItemsIfChanged(sideBar.toolbarItems(startsChats: startsChatsFromHere))
    }
}
