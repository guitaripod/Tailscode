import TailscodeCore
import UIKit

extension ModelPickerViewController {
    #if DEBUG
        func tourMachine(_ index: Int) { pickMachine(index) }

        func tourDoor(_ index: Int) { pickDoor(index) }

        func tourExpand() {
            guard let index = chooser.rows.firstIndex(where: { $0.canExpand && !$0.isExpanded })
            else { return }
            chooser.focus(index)
            _ = chooser.setExpanded(true, at: index)
            applySnapshot(keepingScroll: true)
        }

        func tourSearch(_ text: String) {
            search.isActive = true
            search.searchBar.text = text
            updateSearchResults(for: search)
        }

        func tourPeek(matching modelID: String) {
            guard
                let row = chooser.rows.first(where: { row in
                    if case .candidate(let candidate) = row.kind {
                        return candidate.offers.contains { $0.model.id == modelID }
                    }
                    return false
                }),
                let reading = peekReading(for: row)
            else { return }
            let hue = ModelBadge.chip(
            selection: row.selection, effort: nil, catalog: chooser.sources.flatMap(\.models))
                .map { Theme.Color.modelIdentity($0) } ?? Theme.Color.tertiaryLabel
            let card = ModelPeekViewController(reading: reading, hue: hue)
            card.loadViewIfNeeded()
            let scrim = UIView(frame: view.bounds)
            scrim.backgroundColor = UIColor.black.withAlphaComponent(0.45)
            scrim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(scrim)
            addChild(card)
            let size = card.preferredContentSize
            card.view.frame = CGRect(
                x: (view.bounds.width - size.width) / 2, y: view.bounds.height * 0.34,
                width: size.width, height: size.height)
            card.view.layer.cornerRadius = 26
            card.view.layer.cornerCurve = .continuous
            card.view.clipsToBounds = true
            view.addSubview(card.view)
            card.didMove(toParent: self)
        }

        func tourSelect(matching modelID: String) {
            guard
                let row = chooser.rows.first(where: { row in
                    if case .candidate(let candidate) = row.kind {
                        return candidate.offers.contains { $0.model.id == modelID }
                    }
                    return false
                })
            else { return }
            onSelect(row.pick)
            dismiss(animated: true)
        }
    #endif
}
