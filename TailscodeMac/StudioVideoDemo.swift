import AVFoundation
import AppKit
import CoreVideo
import TailscodeCore

/// Every state the Video lane has, put on the runner without a machine to make one happen. A render
/// is minutes of another machine's card, so the states between pressing Render and holding a clip
/// cannot be reached in a build loop — and they are exactly the states worth looking at. Every board
/// is `ForgeDemo`'s, built from Core's own mutators; the sketch, the posters and the one clip that
/// plays are drawn here with Core Graphics, so nothing crosses a network and nothing a person made
/// is touched. The preference store is never written.
@MainActor
enum StudioVideoDemo {
    /// Puts a state on the runner: `--open forge:<state>` with `empty`, `drafting`, `start` (a first
    /// frame held), `waking`, `queued`, `running`, `collecting`, `done`, `failed`, `cancelled`,
    /// `missing` (a clip the renderer lost, chosen on the stage), `rewrite` (the helper's caption on
    /// its card) or `unset` (no renderer), and anything else is the drafting state.
    static func apply(_ state: String) {
        let name = state.split(separator: ":").first.map(String.init) ?? state
        var board: ForgeBoard
        var clip: URL?
        var lost: Set<String> = []
        var draft: ImageGenRewriteDraft?
        switch name {
        case "empty":
            board = ForgeDemo.board("empty")
            board.describe("")
        case "start":
            board = ForgeDemo.board("history")
            if let path = StudioDemo.write(
                StudioDemo.bokeh(seed: 2, width: 1200, height: 800), named: "video-start")
            {
                board.start(from: .file(path), pictureWidth: 1200, pictureHeight: 800)
            }
        case "waking", "queued", "failed", "unset":
            board = ForgeDemo.board(name)
        case "running", "collecting":
            board = ForgeDemo.board(name)
            var job = board.job
            job.saw(.sketched(sketch()))
            board.saw(job)
        case "cancelled", "stopped":
            board = ForgeDemo.board("stopped")
        case "done":
            board = ForgeDemo.board("done")
            let recipe = board.recipe
            let landed = ForgeEntry(
                id: ForgeDemo.promptID, recipe: recipe, asset: ForgeDemo.asset, finishedAt: Date())
            let kept = [landed] + ForgeDemo.history(recipe)
            board.filled(history: environment("TAILSCODE_VIDEO_CLEAN") == nil ? kept : kept.filter { $0.asset != nil })
            clip = clipFile()
        case "missing":
            board = ForgeDemo.board("history")
            if let newest = board.history.first(where: \.isPlayable) { lost = [newest.id] }
        case "rewrite":
            board = ForgeDemo.board("history")
            board.describe("a lamp room flickers on as dusk falls")
            draft = ImageGenRewriteDraft(
                original: board.recipe.prompt,
                written:
                    "A slow push-in on a white lighthouse lamp room at dusk, the lens catching the last "
                    + "amber light as the lamp flickers on. Waves roll against the granite below, spray "
                    + "drifting through the beam. The sky is violet streaked with orange. Ambient sea "
                    + "wind and the low hum of the lamp starting up.",
                aspect: .landscape, phase: .landed,
                helper: ImageGenHelper(address: "http://arch.ts.net:8081", model: "qwen38", label: "Qwen 3.8 27B"))
        default:
            board = ForgeDemo.board("history")
        }
        seedPosters(for: board)
        ForgeRunner.shared.stage(board, clip: clip, lost: lost)
        let lane = StudioWindowController.shared.video
        lane.stageForDemo(entryID: name == "done" ? ForgeDemo.promptID : lost.first)
        lane.brief.stage(draft: draft)
    }

    private static func sketch() -> ImageGenPreviewFrame {
        let image = StudioDemo.bokeh(seed: 0, width: 640, height: 352, soft: true)
        return ImageGenPreviewFrame(encoding: .png, bytes: StudioDemo.png(image) ?? Data())
    }

    /// A small copy of each kept clip's first frame, for a machine that exists only here. The clip
    /// that just landed has none: its poster is read from the clip itself, which is what plays —
    /// unless a folder of posters is named, which then supplies every one, the landed clip's too.
    private static func seedPosters(for board: ForgeBoard) {
        for (index, entry) in board.history.enumerated() {
            guard let asset = entry.asset else { continue }
            let key = MacClipPosters.key(for: asset, host: ForgeDemo.host)
            if let named = pictureFor(entry: entry) {
                MacClipPosters.seed(named, key: key)
                continue
            }
            guard asset != ForgeDemo.asset else { continue }
            let image = StudioDemo.bokeh(seed: index + 1, width: 256, height: 141)
            MacClipPosters.seed(
                NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)),
                key: key)
        }
    }

    /// A debug build's override, `TAILSCODE_VIDEO_CLIP` for the clip that plays and
    /// `TAILSCODE_VIDEO_POSTERS` for a folder of `<entry id>.png` posters, so a picture of the demo
    /// world can wear real pictures instead of drawn light.
    private static func environment(_ name: String) -> String? {
        #if DEBUG
            return ProcessInfo.processInfo.environment[name].flatMap { $0.isEmpty ? nil : $0 }
        #else
            return nil
        #endif
    }

    private static func pictureFor(entry: ForgeEntry) -> NSImage? {
        guard let folder = environment("TAILSCODE_VIDEO_POSTERS") else { return nil }
        return NSImage(contentsOfFile: (folder as NSString).appendingPathComponent("\(entry.id).png"))
    }

    /// One second of drifting light, written once to a file the stage can play: the demo's only clip,
    /// whichever shelf tile is chosen.
    private static func clipFile() -> URL? {
        if let named = environment("TAILSCODE_VIDEO_CLIP"),
            FileManager.default.fileExists(atPath: named)
        {
            return URL(fileURLWithPath: named)
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("tailscode-studio-demo", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("clip.mp4")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        return writeClip(to: url) ? url : nil
    }

    private static func writeClip(to url: URL) -> Bool {
        let width = 640
        let height = 352
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return false }
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)
        let light = StudioDemo.bokeh(seed: 1, width: width + 96, height: height)
        let space = CGColorSpaceCreateDeviceRGB()
        for frame in 0..<48 {
            var spins = 0
            while !input.isReadyForMoreMediaData, spins < 5_000 {
                usleep(2_000)
                spins += 1
            }
            guard let pool = adaptor.pixelBufferPool else { return false }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { return false }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            {
                context.draw(
                    light, in: CGRect(x: -frame * 2, y: 0, width: width + 96, height: height))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 24))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        return writer.status == .completed
    }
}
