import TailscodeCore
import UIKit

/// The keys a shell needs that a phone's keyboard does not have, in a row above it: Escape, Tab,
/// Control held for the next key, the arrows, the punctuation a path and a pipe are made of, and
/// paste.
final class TerminalKeyBar: UIInputView {
    enum Key: Equatable {
        case press(TerminalKey)
        case text(String)
        case control
        case paste
        case dismiss
    }

    var onKey: ((Key) -> Void)?

    private let controlButton = UIButton(configuration: .gray())

    /// Whether Control is held for the next key typed.
    var controlHeld = false {
        didSet {
            controlButton.configuration?.baseBackgroundColor = controlHeld ? Theme.Color.accent : nil
            controlButton.configuration?.baseForegroundColor = controlHeld ? Theme.Color.onAccent : Theme.Color.label
            controlButton.accessibilityValue = controlHeld ? String(localized: "On") : String(localized: "Off")
        }
    }

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 48), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        let keys: [(String?, String?, Key, String)] = [
            ("esc", nil, .press(.escape), String(localized: "Escape")),
            ("tab", nil, .press(.tab), String(localized: "Tab")),
            ("ctrl", nil, .control, String(localized: "Control")),
            (nil, "arrow.left", .press(.arrowLeft), String(localized: "Left")),
            (nil, "arrow.down", .press(.arrowDown), String(localized: "Down")),
            (nil, "arrow.up", .press(.arrowUp), String(localized: "Up")),
            (nil, "arrow.right", .press(.arrowRight), String(localized: "Right")),
            ("-", nil, .text("-"), "-"), ("/", nil, .text("/"), "/"), ("|", nil, .text("|"), "|"),
            ("~", nil, .text("~"), "~"),
            (nil, "doc.on.clipboard", .paste, String(localized: "Paste")),
            (nil, "keyboard.chevron.compact.down", .dismiss, String(localized: "Hide keyboard")),
        ]
        for (title, symbol, key, spoken) in keys {
            let button = key == .control ? controlButton : UIButton(configuration: .gray())
            var configuration = button.configuration ?? .gray()
            configuration.title = title
            configuration.image = symbol.flatMap { UIImage(systemName: $0) }
            configuration.baseForegroundColor = Theme.Color.label
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = UIFont.monospacedSystemFont(ofSize: 15, weight: .medium)
                return outgoing
            }
            button.configuration = configuration
            button.accessibilityLabel = spoken
            button.addAction(UIAction { [weak self] _ in self?.onKey?(key) }, for: .touchUpInside)
            row.addArrangedSubview(button)
        }
        scroll.addSubview(row)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 48),
            row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerYAnchor),
            scroll.contentLayoutGuide.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
