import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// `agents-film=<seconds>:<out.mp4>`: the wall as a film at exactly sixty frames a second. The
/// wall's clock is held and stepped a sixtieth at a time, each frame is drawn by the window's own
/// renderer into a texture at twice the wall's size and handed to ffmpeg, so the film is as smooth
/// as the wall is on a fast display however long a frame takes to make. Steps land on the tiles in
/// turn while it runs, a sub-agent starts and a context is compacted, so the film shows the wall
/// doing what it does.
enum AgentsFilm {
    static let rate = 60.0
    static let scale = 2.0

    nonisolated(unsafe) private static var take: Take?

    static func run(_ argument: String) {
        let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
        guard take == nil, parts.count == 2, let seconds = Double(parts[0]), seconds > 0,
            let board = AgentsWindow.current
        else {
            say("AGENTS film needs <seconds>:<out.mp4> and an open wall")
            return
        }
        let view = board.watchView
        let width = Int((Double(gtk_widget_get_width(view.widget)) * scale).rounded())
        let height = Int((Double(gtk_widget_get_height(view.widget)) * scale).rounded())
        guard width > 0, height > 0, let made = Take(board: board, width: width, height: height, frames: Int(seconds * rate), path: parts[1])
        else {
            say("AGENTS film could not start")
            return
        }
        take = made
        say("AGENTS film \(width)x\(height) \(made.frames) frames to \(parts[1])")
        step()
    }

    private static func step() {
        Gtk.after(1) {
            guard let current = take else { return }
            if current.next() {
                step()
            } else {
                take = nil
                say("AGENTS film done \(current.written) frames")
            }
        }
    }

    static func note(_ line: String) { say("AGENTS film " + line) }

    private static func say(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    /// One film being made: where it has got to, the encoder it feeds and the clock it holds.
    final class Take {
        let board: AgentsWindow
        let width: Int
        let height: Int
        let frames: Int
        private(set) var written = 0
        private let encoder = Process()
        private let feed = Pipe()
        private let startSeconds: Double
        private let startDate: Date
        private var pixels: [UInt8]
        private var prepared = -1
        private var misses = 0

        init?(board: AgentsWindow, width: Int, height: Int, frames: Int, path: String) {
            self.board = board
            self.width = width
            self.height = height
            self.frames = frames
            startSeconds = board.watchView.context.clock.seconds
            startDate = board.watchView.context.clock.now
            pixels = [UInt8](repeating: 0, count: width * height * 4)
            encoder.executableURL = URL(fileURLWithPath: "/usr/bin/ffmpeg")
            encoder.arguments = [
                "-hide_banner", "-loglevel", "error", "-y", "-f", "rawvideo", "-pix_fmt", "bgra",
                "-video_size", "\(width)x\(height)", "-framerate", "\(Int(AgentsFilm.rate))", "-i", "-",
                "-vf", "scale=out_color_matrix=bt709:out_range=tv,format=yuv420p", "-c:v", "libx264",
                "-preset", "slow", "-crf", "14", "-colorspace", "bt709", "-color_primaries", "bt709",
                "-color_trc", "bt709", "-movflags", "+faststart", path,
            ]
            encoder.standardInput = feed
            do { try encoder.run() } catch { return nil }
        }

        /// Draws and writes one frame; false once the last one is written and the encoder has closed.
        func next() -> Bool {
            let view = board.watchView
            let clock = view.context.clock
            let offset = Double(written) / AgentsFilm.rate
            clock.hold(at: (startSeconds + offset, startDate.addingTimeInterval(offset)))
            if prepared != written {
                prepared = written
                if written % Int(AgentsFilm.rate) == 0 { board.secondPassed() }
                happen(at: written, on: view)
                view.advance(to: startSeconds + offset, by: written == 0 ? 0 : 1 / AgentsFilm.rate)
            }
            let drawn = draw(view.widget)
            if drawn {
                misses = 0
                pixels.withUnsafeBytes { feed.fileHandleForWriting.write(Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: $0.baseAddress!), count: $0.count, deallocator: .none)) }
                written += 1
            } else {
                misses += 1
            }
            guard misses < Self.patience, written < frames else {
                clock.hold(at: nil)
                try? feed.fileHandleForWriting.close()
                encoder.waitUntilExit()
                return false
            }
            return true
        }

        /// How many times in a row a frame may fail to draw before the film gives up: a frame taken
        /// while the wall waits to be laid out again draws nothing, and is taken again once it has been.
        static let patience = 240

        /// What happens on the wall during the film: a step on each working tile in turn, a
        /// sub-agent starting three seconds in and the fullest context compacting at seven.
        private func happen(at frame: Int, on view: AgentsWatchView) {
            let tiles = view.wall.tiles
            guard !tiles.isEmpty else { return }
            var events: [WallEvent] = []
            var contexts: [String: (from: Double, to: Double)] = [:]
            if frame % 42 == 20 {
                let working = tiles.filter { if case .working = $0.state { return true } else { return false } }
                if !working.isEmpty { events.append(WallEvent(kind: .step, tile: working[(frame / 42) % working.count].id)) }
            }
            if frame == 180, let crewed = tiles.first(where: { !$0.workers.isEmpty }) {
                events.append(WallEvent(kind: .workerStarted, tile: crewed.id, worker: crewed.workers.last?.id))
            }
            if frame == 420, let full = tiles.max(by: { ($0.contextShare ?? 0) < ($1.contextShare ?? 0) }),
                let share = full.contextShare
            {
                events.append(WallEvent(kind: .compacted, tile: full.id))
                contexts[full.id] = (share, max(0.1, share - 0.5))
            }
            guard !events.isEmpty else { return }
            view.effects.add(events, at: view.context.seconds, style: view.queueStyle, contexts: contexts)
        }

        private func draw(_ widget: UnsafeMutablePointer<GtkWidget>) -> Bool {
            guard let parent = gtk_widget_get_parent(widget), let snapshot = gtk_snapshot_new() else { return false }
            gtk_snapshot_scale(snapshot, Float(AgentsFilm.scale), Float(AgentsFilm.scale))
            gtk_widget_snapshot_child(parent, widget, snapshot)
            guard gtk_widget_get_allocated_width(widget) > 0, let node = gtk_snapshot_free_to_node(snapshot) else { return false }
            defer { gsk_render_node_unref(node) }
            var viewport = graphene_rect_t()
            _ = graphene_rect_init(&viewport, 0, 0, Float(width), Float(height))
            guard let native = gtk_widget_get_native(widget), let renderer = gtk_native_get_renderer(native),
                let texture = gsk_renderer_render_texture(renderer, node, &viewport)
            else { AgentsFilm.note("no texture"); return false }
            defer { g_object_unref(UnsafeMutableRawPointer(texture)) }
            pixels.withUnsafeMutableBytes { gdk_texture_download(texture, $0.baseAddress, gsize(width * 4)) }
            return true
        }
    }
}
