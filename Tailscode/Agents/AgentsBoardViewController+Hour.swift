import TailscodeCore
import UIKit

extension AgentsBoardViewController {
    func configureHour() {
        hourPane.isHidden = true
        hourPane.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hourPane)
        NSLayoutConstraint.activate([
            hourPane.topAnchor.constraint(equalTo: view.topAnchor),
            hourPane.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hourPane.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hourPane.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        hourPane.hourView.onSelect = { [weak self] lane, rect in self?.peekLane(lane, rect: rect) }
        modeControl.selectedSegmentIndex = 0
        modeControl.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                self.setHour(self.modeControl.selectedSegmentIndex == 1)
            }, for: .valueChanged)
        updateModeControl()
    }

    /// The hour needs a lane label and an hour of bars side by side, which the iPad has room for
    /// and the phone does not. The measure is the board's own width and not its size class: as a
    /// sheet on an iPad the board reads compact however wide the sheet is, which hid the hour from
    /// the one device that draws it.
    func updateModeControl() {
        let wide = traitCollection.userInterfaceIdiom == .pad && view.bounds.width >= Self.hourWidth
        let wanted: UIView? = wide ? modeControl : nil
        if navigationItem.titleView !== wanted { navigationItem.titleView = wanted }
        if !wide, showsHour { setHour(false) }
    }

    static let hourWidth: CGFloat = 500

    func setHour(_ on: Bool) {
        guard on != showsHour else { return }
        showsHour = on
        modeControl.selectedSegmentIndex = on ? 1 : 0
        collectionView.isHidden = on
        hourPane.isHidden = !on
        hourPane.hourView.clearSelection()
        if on { refreshHour() }
    }

    func refreshHour() {
        guard showsHour, hourRefresh == nil else { return }
        hourRefresh = Task { [weak self] in
            let hour = await self?.hub.hour()
            guard let self else { return }
            self.hourRefresh = nil
            guard !Task.isCancelled, let hour else { return }
            self.hourPane.hourView.hour = hour
        }
    }

    private func peekLane(_ lane: AgentHourLane, rect: CGRect) {
        let owner = hourPane.hourView.hour?.lanes.first { $0.id == lane.parentID } ?? lane
        let key = "\(owner.profileID)/\(owner.sessionID)"
        let target = board.row(key).map(AgentsPeekTarget.init(row:))
            ?? board.ask(key).map(AgentsPeekTarget.init(ask:))
            ?? AgentsPeekTarget(lane: owner, key: key)
        presentPeek(target, from: (hourPane.hourView, rect))
    }
}

#if DEBUG
    extension AgentsBoardViewController {
        /// The screenshot launch arguments: `--agent-peek` opens the working row of the demo board,
        /// `--agent-hour` turns to the hour where the screen is wide enough to have one.
        func openForDebug(peek wantsPeek: Bool, hour wantsHour: Bool) {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if wantsHour { self.setHour(true) }
                guard wantsPeek,
                    let row = self.board.working.first(where: { $0.title == "Fix reconnect test" })
                else { return }
                self.presentPeek(AgentsPeekTarget(row: row))
            }
        }
    }
#endif
