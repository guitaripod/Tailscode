import TailscodeCore
import UIKit

#if DEBUG
    extension BrainOpenView {
        /// What a walk step does to the open brain in place of a finger.
        func walk(verb: String, value: String) {
            guard let model = browseModel else { return }
            func step(_ number: String) -> String? {
                Int(number).flatMap { model.steps.indices.contains($0 - 1) ? model.steps[$0 - 1].id : nil }
            }
            switch verb {
            case "click": if let id = step(value) { browse(.click(id, double: false)) }
            case "doubleclick": if let id = step(value) { browse(.click(id, double: true)) }
            case "node": if let id = step(value) { browse(.clickNode(id, double: false)) }
            case "hover": browse(step(value).map { .hover($0) } ?? .hoverLeft)
            case "key":
                for token in value.split(separator: ",") {
                    switch token {
                    case "esc": browse(.key(.escape))
                    case "enter": browse(.key(.enter))
                    case "up": browse(.key(.up))
                    case "down": browse(.key(.down))
                    case "left": browse(.key(.left))
                    case "right": browse(.key(.right))
                    case "space": browse(.key(.space))
                    case "pgdn": browse(.key(.pageDown))
                    case "pgup": browse(.key(.pageUp))
                    default:
                        for character in token { browse(.key(.character(character))) }
                    }
                }
            case "chip":
                if let digit = Int(value), (1...6).contains(digit) {
                    browse(.zoneChip(NeuralZone.filterOrder[digit - 1], solo: false))
                }
            case "solo":
                if let digit = Int(value), (1...6).contains(digit) {
                    browse(.zoneChip(NeuralZone.filterOrder[digit - 1], solo: true))
                }
            case "failed": browse(.failedToggle)
            case "search": browse(.searchText(value))
            case "dive": stage.walk(dive: value)
            case "scroll": account.scroll(by: CGFloat(Double(value) ?? 0))
            case "end": account.scrollToEnd(animated: false)
            case "unfold": account.walkUnfold(Int(value) ?? 1)
            case "reader": account.walkReader(offset: value)
            case "legend": browse(.key(.character("?")))
            case "more": openMore()
            case "less": setListExpanded(false)
            case "sheet": presentReader(focus: step(value))
            case "dismiss": dismissReader()
            case "dump":
                func walk(_ view: UIView, _ depth: Int) {
                    let pad = String(repeating: " ", count: depth)
                    AppLogger.ui.info("dump \(pad)\(type(of: view)) f=\(NSCoder.string(for: view.frame)) a=\(view.alpha) h=\(view.isHidden)")
                    if depth < Int(value) ?? 6 { for child in view.subviews { walk(child, depth + 1) } }
                }
                walk(account, 0)
            default: break
            }
        }
    }
#endif
