import CAdw
import CGtkShim
import Foundation

extension Gtk {
    /// The file chooser, completed back into Swift on the GLib main context. Cancel calls back
    /// with an empty list, so the caller never waits on a dialog that already closed.
    static func openFiles(
        parent: UnsafeMutablePointer<GtkWidget>?, _ handler: @escaping ([String]) -> Void
    ) {
        let box = Unmanaged.passRetained(PathListBox(handler)).toOpaque()
        let callback:
            @convention(c) (
                UnsafePointer<UnsafePointer<CChar>?>?, Int32, UnsafeMutableRawPointer?
            ) -> Void = { paths, count, raw in
                guard let raw else { return }
                let box = Unmanaged<PathListBox>.fromOpaque(raw).takeRetainedValue()
                var result: [String] = []
                if let paths {
                    for index in 0..<Int(count) {
                        if let path = paths[index] { result.append(String(cString: path)) }
                    }
                }
                box.handler(result)
            }
        let window: UnsafeMutablePointer<GtkWindow>? = parent.map {
            ptr(UnsafeMutableRawPointer($0))
        }
        tailscode_file_open(window, callback, box)
    }

    /// The desktop's own folder chooser, completed back into Swift on the GLib main context —
    /// nil when the person cancelled.
    static func selectFolder(
        parent: UnsafeMutablePointer<GtkWidget>?, initial: String? = nil,
        _ handler: @escaping (String?) -> Void
    ) {
        let box = Unmanaged.passRetained(PathBox(handler)).toOpaque()
        let callback: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = {
            path, raw in
            guard let raw else { return }
            let box = Unmanaged<PathBox>.fromOpaque(raw).takeRetainedValue()
            box.handler(path.map { String(cString: $0) })
        }
        let window: UnsafeMutablePointer<GtkWindow>? = parent.map {
            ptr(UnsafeMutableRawPointer($0))
        }
        tailscode_select_folder(window, initial, callback, box)
    }

    /// The clipboard as PNG bytes, or nil when it holds no picture.
    static func readClipboardImage(_ handler: @escaping (Data?) -> Void) {
        let box = Unmanaged.passRetained(ImageBox(handler)).toOpaque()
        let callback: @convention(c) (UnsafeRawPointer?, gsize, UnsafeMutableRawPointer?) -> Void =
            { bytes, length, raw in
                guard let raw else { return }
                let box = Unmanaged<ImageBox>.fromOpaque(raw).takeRetainedValue()
                guard let bytes, length > 0 else {
                    box.handler(nil)
                    return
                }
                box.handler(Data(bytes: bytes, count: Int(length)))
            }
        tailscode_clipboard_read_image(callback, box)
    }

    final class PathListBox {
        let handler: ([String]) -> Void
        init(_ handler: @escaping ([String]) -> Void) { self.handler = handler }
    }

    final class PathBox {
        let handler: (String?) -> Void
        init(_ handler: @escaping (String?) -> Void) { self.handler = handler }
    }

    final class ImageBox {
        let handler: (Data?) -> Void
        init(_ handler: @escaping (Data?) -> Void) { self.handler = handler }
    }
}
