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
    }
#endif
