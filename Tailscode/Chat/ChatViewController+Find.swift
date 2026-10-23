import UIKit

extension ChatViewController {
    /// Text search within the open conversation, with the desktop find bars' semantics: one
    /// match per row, case-insensitive, a live "n of m" count, next/previous that wrap, and the
    /// current hit ringed and scrolled into view.
    func configureFindBar() {
        findBar.backgroundColor = Theme.Color.secondaryBackground
        findBar.layer.cornerRadius = 12
        findBar.layer.cornerCurve = .continuous
        findBar.layer.shadowColor = UIColor.black.cgColor
        findBar.layer.shadowOpacity = 0.15
        findBar.layer.shadowRadius = 8
        findBar.layer.shadowOffset = CGSize(width: 0, height: 2)
        findBar.isHidden = true
        findBar.translatesAutoresizingMaskIntoConstraints = false

        findField.placeholder = String(localized: "Find in conversation")
        findField.returnKeyType = .search
        findField.autocorrectionType = .no
        findField.autocapitalizationType = .none
        findField.addAction(
            UIAction { [weak self] _ in self?.runFind(retarget: true) }, for: .editingChanged)
        findField.addAction(
            UIAction { [weak self] _ in self?.stepFind(1) }, for: .primaryActionTriggered)

        findCountLabel.font = Theme.Ramp.font(.panelDetail)
        findCountLabel.textColor = Theme.Color.secondaryLabel
        findCountLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let previous = UIButton(
            type: .system,
            primaryAction: UIAction(image: UIImage(systemName: "chevron.up")) { [weak self] _ in
                self?.stepFind(-1)
            })
        previous.accessibilityLabel = String(localized: "Previous match")
        let next = UIButton(
            type: .system,
            primaryAction: UIAction(image: UIImage(systemName: "chevron.down")) { [weak self] _ in
                self?.stepFind(1)
            })
        next.accessibilityLabel = String(localized: "Next match")
        let close = UIButton(
            type: .system,
            primaryAction: UIAction(image: UIImage(systemName: "xmark")) { [weak self] _ in
                self?.closeFind()
            })
        close.accessibilityLabel = String(localized: "Close find")

        let row = UIStackView(arrangedSubviews: [findField, findCountLabel, previous, next, close])
        row.axis = .horizontal
        row.spacing = Theme.Spacing.s
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        findBar.addSubview(row)
        view.addSubview(findBar)
        NSLayoutConstraint.activate([
            findBar.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Theme.Spacing.s),
            findBar.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: Theme.Spacing.l),
            findBar.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -Theme.Spacing.l),
            row.topAnchor.constraint(equalTo: findBar.topAnchor, constant: Theme.Spacing.xs),
            row.bottomAnchor.constraint(equalTo: findBar.bottomAnchor, constant: -Theme.Spacing.xs),
            row.leadingAnchor.constraint(equalTo: findBar.leadingAnchor, constant: Theme.Spacing.m),
            row.trailingAnchor.constraint(
                equalTo: findBar.trailingAnchor, constant: -Theme.Spacing.m),
        ])
    }

    func openFind() {
        findVisible = true
        findBar.isHidden = false
        view.bringSubviewToFront(findBar)
        findField.becomeFirstResponder()
        brainSearch.start()
        runFind(retarget: true)
    }

    func closeFind() {
        brainSearch.cancel()
        findVisible = false
        findBar.isHidden = true
        findField.resignFirstResponder()
        setFindHighlight(nil)
        findMatches = []
        findCountLabel.text = nil
    }

    func runFind(retarget: Bool) {
        let previousID = findMatches.indices.contains(findCursor) ? findMatches[findCursor] : nil
        let store = brain.store
        let warm = brainSearch.isWarm
        findMatches = ChatFind.matchingIDs(
            needle: findField.text ?? "", orderedIDs: orderedIDs, rowsByID: rowsByID,
            brain: { warm ? store.searchText(for: $0) : store.indexedSearchText(for: $0) })
        findCursor = ChatFind.cursor(
            matches: findMatches, previousID: previousID, previousCursor: findCursor,
            retarget: retarget)
        if findMatches.isEmpty {
            findCountLabel.text = (findField.text ?? "").trimmingCharacters(in: .whitespaces).isEmpty
                ? nil : String(localized: "No matches")
            setFindHighlight(nil)
            return
        }
        updateFindCount()
        applyFindHighlight(scroll: retarget)
    }

    private func stepFind(_ delta: Int) {
        guard !findMatches.isEmpty else { return }
        findCursor = (findCursor + delta + findMatches.count) % findMatches.count
        updateFindCount()
        applyFindHighlight(scroll: true)
    }

    private func updateFindCount() {
        findCountLabel.text = findMatches.isEmpty
            ? String(localized: "No matches")
            : "\(findCursor + 1)/\(findMatches.count)"
    }

    private func applyFindHighlight(scroll: Bool) {
        guard findMatches.indices.contains(findCursor) else {
            setFindHighlight(nil)
            return
        }
        let id = findMatches[findCursor]
        setFindHighlight(id)
        guard scroll else { return }
        userScrolledUp = true
        scrollTo(id: id)
        landFind(on: id)
    }

    /// A match inside a brain opens that turn's brain and puts the cursor on the step that holds
    /// the words.
    private func landFind(on rowID: String) {
        guard case .brain(let brainRow)? = rowsByID[rowID]?.content,
            let step = brain.store.stepMatching(findField.text ?? "", in: brainRow.turnID)
        else { return }
        if !brain.store.isOpen(brainRow.turnID) { toggleBrain(brainRow.turnID) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            for case let cell as NeuralBrainCell in self.collectionView.visibleCells
            where cell.brainRow.turnID == brainRow.turnID {
                cell.brainRow.openView?.browse(.click(step, double: false))
            }
        }
    }

    /// The current hit carries an accent ring; rows scroll in and out of reuse, so the ring is
    /// re-applied in `willDisplay` and cleared here on whichever cell shows the old id.
    private func setFindHighlight(_ id: String?) {
        let previous = findHighlightedID
        findHighlightedID = id
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard let cellID = dataSource.itemIdentifier(for: indexPath),
                cellID == previous || cellID == id,
                let cell = collectionView.cellForItem(at: indexPath)
            else { continue }
            decorateFindRing(cell, on: cellID == id)
        }
    }

    /// The match wears the palette's own search wash behind an accent edge — a ring alone is easy
    /// to lose in a long transcript, and the wash is the one slot authored for exactly this.
    func decorateFindRing(_ cell: UICollectionViewCell, on: Bool) {
        cell.layer.cornerRadius = on ? 10 : 0
        cell.layer.cornerCurve = .continuous
        cell.layer.borderWidth = on ? 2 : 0
        cell.layer.borderColor =
            on
            ? Theme.Color.accent.withAlphaComponent(0.6).resolvedColor(with: traitCollection).cgColor
            : nil
        cell.backgroundColor = on ? Theme.Color.findHit : nil
    }
}
