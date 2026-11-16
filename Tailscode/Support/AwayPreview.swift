import MidgarCore
#if DEBUG
    import CodingAgentKit
    import SwiftUI
    import TailscodeCore
    import UIKit

    /// The head where the app is not in front, drawn in the app for a headless look: a simulator
    /// screenshot never shows a Live Activity or a notification's face, so the real views of both
    /// are hosted here and photographed instead.
    ///
    /// `--away-lock <dark|light>` hosts the Lock Screen card and the expanded island's three
    /// regions over four states, `--away-face` the notification's face at the sizes it is drawn,
    /// and `--neural-share <dark|light> [look]` the share sheet's poster, which also writes the
    /// posters at both looks to `Library/Caches/neural-share/` for a close look.
    @MainActor
    enum AwayPreview {
        static func viewControllerIfRequested() -> UIViewController? {
            let arguments = CommandLine.arguments
            if let flag = arguments.firstIndex(of: "--away-lock") {
                let dark = !(arguments.indices.contains(flag + 1) && arguments[flag + 1] == "light")
                return UIHostingController(rootView: LockWall(dark: dark))
            }
            if arguments.contains("--away-face") {
                return UIHostingController(rootView: FaceWall())
            }
            if arguments.contains("--away-unbounded") {
                let drawn = drawUnbounded()
                MidgarLog.info("away unbounded: \(drawn) views drawn under unbounded proposals", category: .ui)
                return UIHostingController(rootView: Text(verbatim: "away unbounded: \(drawn)"))
            }
            if let flag = arguments.firstIndex(of: "--neural-share") {
                let dark = !(arguments.indices.contains(flag + 1) && arguments[flag + 1] == "light")
                let look = arguments.indices.contains(flag + 2) ? arguments[flag + 2] : "app"
                return SharePreview(dark: dark, lookID: look)
            }
            return nil
        }

        /// Draws every sample card at every size, and a usage bar, under the proposals a system
        /// surface may make that the Lock Screen never does: a width without bound, a height
        /// without bound, both, and none at all. A view that turns such a size into a position
        /// ends the widget's process (`view origin is invalid`), three times for every update, and
        /// nothing on the phone's own screen shows it; here the same views either draw or bring
        /// this launch down where it can be seen. Returns how many were drawn.
        private static func drawUnbounded() -> Int {
            let proposals = [
                ProposedViewSize(width: .infinity, height: 160), ProposedViewSize(width: 360, height: .infinity),
                ProposedViewSize(width: .infinity, height: .infinity), ProposedViewSize.unspecified,
            ]
            var drawn = 0
            func draw(_ view: some View) {
                for proposal in proposals {
                    let renderer = ImageRenderer(content: view)
                    renderer.proposedSize = proposal
                    _ = renderer.cgImage
                    drawn += 1
                }
            }
            for size in LiveActivitySize.allCases {
                for sample in CardSamples.all() {
                    let model = CardModel(
                        state: sample.state, title: sample.title, server: CardSamples.server,
                        isStale: sample.name == "QUIET", seedKey: sample.title)
                    draw(LockScreenCard(model: model, size: size, drawsGround: true))
                }
            }
            draw(GaugeBar(fraction: 0.4, color: .accentColor))
            return drawn
        }

        /// Every sample card at every size, with its expanded island and the compact island it
        /// shrinks to, the way the Lock Screen and the Dynamic Island will draw them.
        private struct LockWall: View {
            let dark: Bool

            var body: some View {
                ZStack {
                    LinearGradient(
                        colors: dark
                            ? [Color(red: 0.10, green: 0.14, blue: 0.2), Color(red: 0.03, green: 0.05, blue: 0.08)]
                            : [Color(red: 0.86, green: 0.8, blue: 0.9), Color(red: 0.95, green: 0.93, blue: 0.9)],
                        startPoint: .top, endPoint: .bottom
                    ).ignoresSafeArea()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(sizes, id: \.self) { size in
                                ForEach(CardSamples.all(), id: \.name) { sample in
                                    Text("\(size.rawValue.uppercased()) · \(sample.name)")
                                        .font(.caption2.monospaced()).opacity(0.6)
                                    LockScreenCard(model: model(sample), size: size, drawsGround: true)
                                        .clipShape(RoundedRectangle(cornerRadius: LockScreenCard.corner, style: .continuous))
                                }
                            }
                            if showsIslands {
                                ForEach(CardSamples.all(), id: \.name) { sample in
                                    Text("ISLAND · \(sample.name)").font(.caption2.monospaced()).opacity(0.6)
                                    IslandPreview(sample: sample)
                                    compact(sample)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 60)
                    }
                }
                .preferredColorScheme(dark ? .dark : .light)
            }

            /// `TAILSCODE_CARD_SIZE` narrows the photograph to one size, or to the islands alone.
            private var only: String? { ProcessInfo.processInfo.environment["TAILSCODE_CARD_SIZE"] }

            private var sizes: [LiveActivitySize] {
                guard let only, !only.isEmpty else { return LiveActivitySize.allCases }
                return LiveActivitySize(rawValue: only).map { [$0] } ?? []
            }

            private var showsIslands: Bool { only == nil || only == "" || only == "island" }

            private func model(_ sample: CardSamples.Sample) -> CardModel {
                CardModel(
                    state: sample.state, title: sample.title, server: CardSamples.server,
                    isStale: sample.name == "QUIET", seedKey: sample.title)
            }

            private func compact(_ sample: CardSamples.Sample) -> some View {
                let model = model(sample)
                return HStack(spacing: 0) {
                    IslandDot(model: model, size: 22)
                    Spacer(minLength: 120)
                    IslandClock(model: model)
                }
                .padding(.horizontal, 10)
                .frame(height: 36)
                .background(Color.black, in: Capsule())
                .frame(width: 250)
                .environment(\.colorScheme, .dark)
            }
        }

        private struct FaceWall: View {
            var body: some View {
                ZStack {
                    Color(white: 0.16).ignoresSafeArea()
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(NoticeSample.allCases.prefix(4), id: \.rawValue) { sample in
                            HStack(spacing: 18) {
                                ForEach([120.0, 46.0, 34.0], id: \.self) { side in
                                    Image(
                                        uiImage: NoticeFace.image(
                                            for: NoticePresentation.of(sample.wire.kind),
                                            glyph: sample.wire.glyph, side: side * 3)
                                    )
                                    .resizable()
                                    .frame(width: side, height: side)
                                }
                                Text(sample.rawValue).font(.caption.monospaced()).foregroundStyle(.white)
                            }
                        }
                    }
                    .padding(.top, 60)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.leading, 24)
                }
                .preferredColorScheme(.dark)
            }
        }

        private final class SharePreview: UIViewController {
            private let dark: Bool
            private let lookID: String
            private var shown = false

            init(dark: Bool, lookID: String) {
                self.dark = dark
                self.lookID = lookID
                super.init(nibName: nil, bundle: nil)
                overrideUserInterfaceStyle = dark ? .dark : .light
            }

            required init?(coder: NSCoder) { nil }

            override func viewDidAppear(_ animated: Bool) {
                super.viewDidAppear(animated)
                guard !shown else { return }
                shown = true
                let turn = Self.turn()
                Self.export(turn: turn)
                NeuralShareViewController.present(
                    turn: turn, prompt: Self.prompt,
                    look: NeuralShare.looks.first { $0.id == lookID } ?? .app, from: self)
            }

            private static let prompt =
                "Make a product demonstration using mock data but the real apps .mp4 i can share on twitter and keep it under a minute"

            private static func turn() -> NeuralTurn {
                let messages = NeuralDemo.turn(prefix: "share-").map { message -> ChatMessage in
                    var copy = message
                    if copy.role == .assistant { copy.modelID = "claude-fable-1" }
                    return copy
                }
                let turns = NeuralTurns.partition(messages: messages, running: false)
                return turns.last ?? NeuralTurn(id: "share")
            }

            private static func export(turn: NeuralTurn) {
                let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("neural-share", isDirectory: true)
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for dark in [true, false] {
                    for look in NeuralShare.looks {
                        let palette = NeuralShare.headPalette(style: look, dark: dark)
                        let hero = NeuralShareHero.render(
                            model: NeuralBrainModel(turn: turn), palette: palette,
                            size: NeuralShareHero.size(width: 1936))
                        guard
                            let data = NeuralShareRenderer.png(
                                turn: turn, prompt: prompt, look: look, dark: dark, hero: hero,
                                scale: 1)
                        else { continue }
                        let name = "poster-\(look.id)-\(dark ? "dark" : "light").png"
                        try? data.write(to: directory.appendingPathComponent(name))
                        MidgarLog.info(
                            "neural-share: wrote \(directory.path)/\(name)", category: .ui)
                    }
                }
            }
        }
    }
#endif
