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
            if let flag = arguments.firstIndex(of: "--neural-share") {
                let dark = !(arguments.indices.contains(flag + 1) && arguments[flag + 1] == "light")
                let look = arguments.indices.contains(flag + 2) ? arguments[flag + 2] : "app"
                return SharePreview(dark: dark, lookID: look)
            }
            return nil
        }

        private struct Sample {
            let state: ChatActivityAttributes.ContentState
            let title: String
            let name: String
        }

        private static var samples: [Sample] {
            let now = Date()
            func state(
                _ phase: ChatActivityAttributes.ContentState.Phase, text: String, tool: String?,
                count: Int, detail: LiveActivityDetail, symbol: String, tone: ActivityTone,
                ended: TimeInterval? = nil, ran: TimeInterval, glyph: NeuralGlyphWire?
            ) -> ChatActivityAttributes.ContentState {
                let began = now.addingTimeInterval(-ran)
                return ChatActivityAttributes.ContentState(
                    phase: phase, statusText: text, lastTool: tool, toolCount: count,
                    startedAt: began, endedAt: ended.map { began.addingTimeInterval($0) },
                    title: nil, symbol: symbol, tone: tone.rawValue, detail: detail.rawValue,
                    background: nil, glyph: glyph)
            }
            return [
                Sample(
                    state: state(
                        .tool, text: "Reading", tool: "Read", count: 4, detail: .tool,
                        symbol: "doc.text", tone: .live, ran: 72,
                        glyph: NeuralGlyphWire(
                            zones: [1, 3, 0, 1, 0, 0], active: NeuralZone.sense.rawValue,
                            eye: NeuralTone.live.rawValue)),
                    title: "Fix the Linux build", name: "WORKING"),
                Sample(
                    state: state(
                        .approval, text: "Approval", tool: "Bash", count: 6, detail: .approval,
                        symbol: "hand.raised", tone: .attention, ran: 220,
                        glyph: NeuralGlyphWire(
                            zones: [1, 3, 0, 2, 0, 0], active: NeuralZone.shell.rawValue,
                            eye: NeuralTone.attention.rawValue)),
                    title: "Fix the Linux build", name: "NEEDS YOU"),
                Sample(
                    state: state(
                        .error, text: "Failed", tool: nil, count: 6, detail: .failed,
                        symbol: "exclamationmark.triangle", tone: .danger, ended: 151, ran: 400,
                        glyph: NeuralGlyphWire(
                            zones: [1, 3, 0, 5, 0, 0], failed: 1 << NeuralZone.shell.rawValue,
                            active: NeuralZone.shell.rawValue, eye: NeuralTone.danger.rawValue)),
                    title: "Fix the Linux build", name: "FAILED"),
                Sample(
                    state: state(
                        .done, text: "Done", tool: nil, count: 25, detail: .finished,
                        symbol: "checkmark.circle", tone: .live, ended: 505, ran: 900,
                        glyph: NeuralGlyphWire(
                            zones: [2, 3, 2, 18, 2, 2], eye: NeuralTone.identity.rawValue,
                            hue: "#d97757", hueLight: "#d97757", reads: 3)),
                    title: "Fix the Linux build", name: "DONE"),
                Sample(
                    state: state(
                        .tool, text: "Running Bash", tool: "Bash", count: 9, detail: .tool,
                        symbol: "terminal", tone: .live, ran: 41, glyph: nil),
                    title: "A card a server wrote (no head sent)", name: "PLAIN"),
            ]
        }

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
                            ForEach(AwayPreview.samples, id: \.name) { sample in
                                Text(sample.name).font(.caption2.monospaced()).opacity(0.6)
                                lockCard(sample)
                                island(sample)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 60)
                    }
                }
                .preferredColorScheme(dark ? .dark : .light)
            }

            private func lockCard(_ sample: Sample) -> some View {
                LockScreenView(
                    state: sample.state, title: sample.title, serverName: "arch", isStale: false
                )
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }

            private func island(_ sample: Sample) -> some View {
                HStack(spacing: 10) {
                    HeadIcon(state: sample.state, width: 38, dimmed: false)
                    IslandTitle(state: sample.state, title: sample.title, isStale: false)
                    Spacer(minLength: 0)
                    ElapsedView(state: sample.state, isStale: false)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.black, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
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
