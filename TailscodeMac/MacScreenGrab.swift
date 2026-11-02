import AppKit
import TailscodeCore

/// A region of the screen, dragged with the system's own interactive capture. The crosshair, the
/// window snapping and Escape are macOS's; what comes back is a file in this app's temporary
/// folder, read as a picture and removed. The store build is sandboxed and is not offered it.
@MainActor
enum MacScreenGrab {
    enum Outcome {
        case picture(PendingAttachment)
        case cancelled
        case failed(String)
    }

    private static let tool = "/usr/sbin/screencapture"

    static var isAvailable: Bool {
        #if TAILSCODE_MAS
            return false
        #else
            return FileManager.default.isExecutableFile(atPath: tool)
        #endif
    }

    static func grab(then done: @escaping @MainActor (Outcome) -> Void) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tailscode-grab-\(UUID().uuidString).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["-i", "-x", "-o", url.path]
        process.terminationHandler = { _ in
            Task { @MainActor in
                defer { try? FileManager.default.removeItem(at: url) }
                guard FileManager.default.fileExists(atPath: url.path) else {
                    done(.cancelled)
                    return
                }
                switch AttachmentIntake.read(path: url.path) {
                case .success(let read):
                    done(.picture(PendingAttachment(name: "screen.png", mime: read.mime, data: read.data)))
                case .failure(let refusal):
                    done(.failed(refusal.message))
                }
            }
        }
        do {
            try process.run()
        } catch {
            done(.failed(Localized.text("The screen could not be captured.")))
        }
    }
}
