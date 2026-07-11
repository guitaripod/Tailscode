import UIKit

final class RingGaugeView: UIView {
    private let trackLayer = CAShapeLayer()
    private let progressLayer = CAShapeLayer()
    private let percentLabel = UILabel()
    private let lineWidth: CGFloat = 10
    private var currentColor: UIColor = Theme.Color.opencode

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        trackLayer.fillColor = UIColor.clear.cgColor
        trackLayer.lineWidth = lineWidth
        layer.addSublayer(trackLayer)

        progressLayer.fillColor = UIColor.clear.cgColor
        progressLayer.lineWidth = lineWidth
        progressLayer.lineCap = .round
        progressLayer.strokeEnd = 0
        layer.addSublayer(progressLayer)

        percentLabel.font = .systemFont(ofSize: 20, weight: .bold)
        percentLabel.textColor = Theme.Color.label
        percentLabel.textAlignment = .center
        percentLabel.adjustsFontSizeToFitWidth = true
        percentLabel.minimumScaleFactor = 0.6
        percentLabel.text = "—"
        percentLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(percentLabel)
        NSLayoutConstraint.activate([
            percentLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            percentLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            percentLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.72),
        ])

        refreshColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            (view: RingGaugeView, _: UITraitCollection) in
            view.refreshColors()
        }
    }

    override var intrinsicContentSize: CGSize { CGSize(width: 104, height: 104) }

    override func layoutSubviews() {
        super.layoutSubviews()
        let radius = (min(bounds.width, bounds.height) - lineWidth) / 2
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let path = UIBezierPath(
            arcCenter: center,
            radius: max(radius, 0),
            startAngle: -.pi / 2,
            endAngle: -.pi / 2 + 2 * .pi,
            clockwise: true)
        trackLayer.path = path.cgPath
        progressLayer.path = path.cgPath
    }

    func configure(fraction: Double, color: UIColor, percentText: String) {
        percentLabel.text = percentText
        currentColor = color
        progressLayer.strokeColor = color.resolvedColor(with: traitCollection).cgColor
        let target = CGFloat(min(max(fraction, 0), 1))
        let from = progressLayer.presentation()?.strokeEnd ?? progressLayer.strokeEnd
        progressLayer.strokeEnd = target
        let animation = CABasicAnimation(keyPath: "strokeEnd")
        animation.fromValue = from
        animation.toValue = target
        animation.duration = 0.4
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        progressLayer.add(animation, forKey: "strokeEnd")
    }

    private func refreshColors() {
        trackLayer.strokeColor = Theme.Color.separator.resolvedColor(with: traitCollection).cgColor
        progressLayer.strokeColor = currentColor.resolvedColor(with: traitCollection).cgColor
    }
}
