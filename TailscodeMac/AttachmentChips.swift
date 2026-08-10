import AppKit
import TailscodeCore

/// The files waiting to ride along with the next prompt, each as one removable chip. The chip
/// removes by id, never by position — two queued clicks by position would delete the wrong file.
@MainActor
final class AttachmentChips: NSView {
    var onRemove: ((UUID) -> Void)?

    private let row = NSStackView()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true

        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = MacTheme.Spacing.xs
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func set(_ attachments: [PendingAttachment]) {
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        isHidden = attachments.isEmpty
        for attachment in attachments {
            let id = attachment.id
            let title =
                "\(attachment.name) · \(AttachmentIntake.sizeText(attachment.data.count))  ✕"
            let chip = RowKit.ActionButton(title: title) { [weak self] in
                self?.onRemove?(id)
            }
            chip.bezelStyle = .rounded
            chip.controlSize = .small
            chip.font = MacTheme.Ramp.font(.panelFootnote)
            chip.toolTip = attachment.name
            chip.translatesAutoresizingMaskIntoConstraints = false
            row.addArrangedSubview(chip)
        }
    }
}
