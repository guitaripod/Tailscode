import AppKit

/// The transcript's rows, placed by hand rather than by a stack view.
///
/// A stack view is one system of constraints: every row's top hangs off the bottom of the row
/// above it and every row's width is the column's, so the layout engine holds the whole
/// conversation as a single problem, and anything that adds a constraint to it — a thought opened,
/// a tool call arriving mid-turn, a batch of history — is solved again against all of it. On a
/// transcript of three hundred and fifty rows that was fifty to a hundred and fifty milliseconds
/// for one click on a thought, nearly all of it the solver walking rows nobody had touched.
///
/// Here every row keeps its own constraints inside a host this column positions by frame, so no
/// constraint joins one row to another or to the column, and a change costs the row it happened
/// in. The column answers the few questions the transcript asked of its stack — the rows in
/// order, where one goes, the spacing between them — and a row taken out with
/// `removeFromSuperview` leaves the column with its host, exactly as it left the stack.
@MainActor
final class TranscriptColumn: NSView {
    var spacing: CGFloat = 0 {
        didSet { if spacing != oldValue { needsLayout = true } }
    }
    private(set) var arrangedSubviews: [NSView] = []
    private var hosts: [ObjectIdentifier: RowHost] = [:]
    private var contentHeight: CGFloat = 0
    private var placing = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: contentHeight)
    }

    func addArrangedSubview(_ row: NSView) {
        insertArrangedSubview(row, at: arrangedSubviews.count)
    }

    func insertArrangedSubview(_ row: NSView, at index: Int) {
        if row.superview != nil { row.removeFromSuperview() }
        let host = RowHost(row: row, width: bounds.width)
        host.column = self
        hosts[ObjectIdentifier(row)] = host
        arrangedSubviews.insert(row, at: min(max(0, index), arrangedSubviews.count))
        addSubview(host)
        needsLayout = true
    }

    /// The host whose row has just been taken out goes with it, so the column never holds a gap
    /// where a row used to be.
    fileprivate func hostLost(_ host: RowHost) {
        hosts[ObjectIdentifier(host.row)] = nil
        if let index = arrangedSubviews.firstIndex(where: { $0 === host.row }) {
            arrangedSubviews.remove(at: index)
        }
        host.column = nil
        host.removeFromSuperview()
        needsLayout = true
    }

    /// A row that changed height by itself — words arriving, a body opening, a picture decoding —
    /// moves every row under it, which only the column can do.
    fileprivate func rowResized() {
        guard !placing else { return }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        place()
    }

    /// Every row at the column's width, one under the other, at the height it last resolved to; a
    /// hidden row takes no room, the way a stack view detaches it. A row given a new width, or one
    /// that has never been laid out, resolves inside its host later in the same layout pass and
    /// says so, which brings the column back here before anything is drawn — one pass for every
    /// row the window just narrowed instead of a forced layout per row.
    private func place() {
        placing = true
        defer { placing = false }
        let width = bounds.width
        let scale = window?.backingScaleFactor ?? 2
        var y: CGFloat = 0
        var placedAny = false
        for row in arrangedSubviews {
            guard let host = hosts[ObjectIdentifier(row)] else { continue }
            host.isHidden = row.isHidden
            guard !row.isHidden else { continue }
            if placedAny { y += spacing }
            let height = (row.frame.height * scale).rounded(.up) / scale
            let frame = NSRect(x: 0, y: y, width: width, height: height)
            if host.frame != frame { host.frame = frame }
            y += height
            placedAny = true
        }
        guard contentHeight != y else { return }
        contentHeight = y
        invalidateIntrinsicContentSize()
    }
}

/// One row's own room: the row's constraints end at this view's edges, which are frames the
/// column sets, so nothing a row asks of the layout engine reaches another row.
///
/// The row hangs from the top and is as wide as the host — or, for a row that hugs its width at
/// required, never wider — and its height is whatever its own content needs, pulled toward the
/// least of that at the priority fitting a view to its content uses, which is what the stack's
/// hugging did.
@MainActor
private final class RowHost: NSView {
    let row: NSView
    weak var column: TranscriptColumn?
    /// A stack view takes a hidden row out of the layout and puts it back when it shows again, so
    /// the column has to hear about both.
    private var visibility: NSKeyValueObservation?

    init(row: NSView, width: CGFloat) {
        self.row = row
        super.init(frame: NSRect(x: 0, y: 0, width: max(1, width), height: 0))
        translatesAutoresizingMaskIntoConstraints = true
        autoresizingMask = []
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        let stretches = row.contentHuggingPriority(for: .horizontal) < .required
        let least = row.heightAnchor.constraint(equalToConstant: 0)
        least.priority = .fittingSizeCompression
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            stretches
                ? row.trailingAnchor.constraint(equalTo: trailingAnchor)
                : row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            least,
        ])
        row.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(rowFrameChanged), name: NSView.frameDidChangeNotification,
            object: row)
        visibility = row.observe(\.isHidden) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.column?.rowResized() }
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }

    @objc private func rowFrameChanged() {
        column?.rowResized()
    }

    override func willRemoveSubview(_ subview: NSView) {
        super.willRemoveSubview(subview)
        guard subview === row else { return }
        NotificationCenter.default.removeObserver(
            self, name: NSView.frameDidChangeNotification, object: row)
        visibility = nil
        column?.hostLost(self)
    }
}
