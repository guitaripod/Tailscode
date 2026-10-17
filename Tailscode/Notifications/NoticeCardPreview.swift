#if DEBUG
    import SwiftUI
    import TailscodeCore
    import UIKit

    /// The long look drawn on its own, for a headless look at it: `--notice-card <sample>` opens
    /// the app on the card the notification content extension would draw for that sample, on the
    /// dark ground it is drawn over. Nothing here is reachable in a release build.
    @MainActor
    enum NoticeCardPreview {
        static func viewControllerIfRequested() -> UIViewController? {
            let arguments = CommandLine.arguments
            if let frame = LongLookFrame.ifRequested(arguments) { return frame }
            guard let flag = arguments.firstIndex(of: "--notice-card"),
                arguments.indices.contains(flag + 1),
                let sample = NoticeSample(rawValue: arguments[flag + 1])
            else { return nil }
            let model = NoticeCardModel()
            model.show(
                title: sample.title, subtitle: "", body: "", wire: sample.wire, date: Date())
            let host = UIHostingController(rootView: PreviewGround(model: model))
            host.view.backgroundColor = UIColor(white: 0.08, alpha: 1)
            return host
        }

        private struct PreviewGround: View {
            let model: NoticeCardModel

            var body: some View {
                ZStack {
                    LinearGradient(
                        colors: [Color(white: 0.16), Color(white: 0.06)], startPoint: .top,
                        endPoint: .bottom
                    ).ignoresSafeArea()
                    NoticeCardView(model: model)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
                        .padding(14)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(.top, 60)
                }
                .preferredColorScheme(.dark)
            }
        }

        /// The extension as the system frames it, for `--notice-long-look <sample>`: the real
        /// `NotificationViewController` inside a clipped card that opens at the Info.plist's
        /// initial ratio of the width and then takes whatever height the extension asks for, as
        /// the notification centre does. What is clipped here is clipped on the phone.
        @MainActor
        private final class LongLookFrame: UIViewController {
            private static let initialRatio: CGFloat = 0.7
            private let sample: NoticeSample
            private let content = NotificationViewController()
            private let card = UIView()
            private var cardHeight: NSLayoutConstraint?
            private var shown = false

            init(sample: NoticeSample) {
                self.sample = sample
                super.init(nibName: nil, bundle: nil)
            }

            required init?(coder: NSCoder) { nil }

            static func ifRequested(_ arguments: [String]) -> UIViewController? {
                guard let flag = arguments.firstIndex(of: "--notice-long-look"),
                    arguments.indices.contains(flag + 1),
                    let sample = NoticeSample(rawValue: arguments[flag + 1])
                else { return nil }
                return LongLookFrame(sample: sample)
            }

            override func viewDidLoad() {
                super.viewDidLoad()
                view.backgroundColor = UIColor(white: 0.08, alpha: 1)
                card.backgroundColor = .secondarySystemBackground
                card.layer.cornerRadius = 28
                card.layer.cornerCurve = .continuous
                card.clipsToBounds = true
                card.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(card)
                let width = card.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -28)
                let height = card.heightAnchor.constraint(equalToConstant: 0)
                cardHeight = height
                NSLayoutConstraint.activate([
                    card.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 40),
                    card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                    width, height,
                ])
                addChild(content)
                content.view.translatesAutoresizingMaskIntoConstraints = false
                card.addSubview(content.view)
                NSLayoutConstraint.activate([
                    content.view.topAnchor.constraint(equalTo: card.topAnchor),
                    content.view.leadingAnchor.constraint(equalTo: card.leadingAnchor),
                    content.view.trailingAnchor.constraint(equalTo: card.trailingAnchor),
                    content.view.bottomAnchor.constraint(equalTo: card.bottomAnchor),
                ])
                content.didMove(toParent: self)
            }

            override func viewDidLayoutSubviews() {
                super.viewDidLayoutSubviews()
                guard !shown, view.bounds.width > 0 else { return }
                shown = true
                cardHeight?.constant = ((view.bounds.width - 28) * Self.initialRatio).rounded()
                view.layoutIfNeeded()
                content.show(
                    title: sample.title, subtitle: "", body: "", wire: sample.wire, date: Date())
            }

            override func preferredContentSizeDidChange(
                forChildContentContainer container: any UIContentContainer
            ) {
                super.preferredContentSizeDidChange(forChildContentContainer: container)
                cardHeight?.constant = container.preferredContentSize.height
                UIView.animate(withDuration: 0.25) { self.view.layoutIfNeeded() }
            }
        }
    }
#endif
