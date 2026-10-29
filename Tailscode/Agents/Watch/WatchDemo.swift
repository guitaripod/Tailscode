#if DEBUG
    import QuartzCore
    import TailscodeCore
    import UIKit

    extension WatchViewController {
        static var demoScene: String? {
            guard CommandLine.arguments.contains("--demo") else { return nil }
            return ProcessInfo.processInfo.environment["TAILSCODE_WATCH"]
        }

        /// `TAILSCODE_WATCH_EVENTS=1` plays a short script of synthetic effects (an ask, a finish, a
        /// worker starting) every six seconds, so a screenshot shows the wall in motion. It reads no
        /// tower and only exists in a Debug build.
        func startDemoScriptIfAsked() {
            guard ProcessInfo.processInfo.environment["TAILSCODE_WATCH_EVENTS"] == "1", demoTask == nil else {
                return
            }
            demoTask = Task { [weak self] in
                var step = 0
                try? await Task.sleep(for: .seconds(1))
                while !Task.isCancelled {
                    guard let self else { return }
                    self.playDemo(step: step)
                    step += 1
                    try? await Task.sleep(for: .seconds(6))
                }
            }
        }

        /// `TAILSCODE_WATCH_UI` puts one piece of the wall's own interface in view a moment after it
        /// opens, so each can be photographed: the controls, the style sheet, a peek, a hold half done.
        func startDemoUIIfAsked() {
            guard let ui = ProcessInfo.processInfo.environment["TAILSCODE_WATCH_UI"] else { return }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2.2))
                guard let self else { return }
                switch ui {
                case "controls": self.showControls()
                case "style": self.presentStyle()
                case "peek":
                    if let tile = self.stage.wall.tiles.first { self.presentPeek(tile: tile.id) }
                case "hold": self.holdForDemo()
                default: break
                }
            }
        }

        private func holdForDemo() {
            guard let tile = stage.wall.tiles.first(where: { $0.state.isNeedsYou }),
                let frame = wordsView.tileView(tile.id)?.pillFrame(.hold)
            else { return }
            let t = CACurrentMediaTime()
            stage.beginHold(tile: tile.id, at: CGPoint(x: frame.midX, y: frame.midY), t: t - 0.45)
            updateCadence()
        }

        private func playDemo(step: Int) {
            let tiles = stage.wall.tiles
            guard !tiles.isEmpty else { return }
            let first = tiles[0].id
            let second = tiles[(step + 1) % tiles.count].id
            let host = tiles.first { !$0.workers.isEmpty } ?? tiles[0]
            let events: [WallEvent]
            switch step % 3 {
            case 0:
                events = [WallEvent(kind: .asked, tile: first)]
            case 1:
                events = [WallEvent(kind: .finished, tile: second), WallEvent(kind: .step, tile: first)]
            default:
                events = [
                    WallEvent(kind: .workerStarted, tile: host.id, worker: host.workers.first?.id),
                    WallEvent(kind: .failed, tile: second),
                ]
            }
            feed.inject(events, style: style)
            wake()
        }
    }
#endif
