import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// A region of the screen, picked by the desktop rather than by this app.
///
/// A Wayland client cannot read the screen, and drawing its own crosshair over other windows is not
/// something a compositor allows either, so the drag belongs to the desktop portal's interactive
/// screenshot: the compositor draws the picker, the person drags, and what comes back is a file the
/// portal wrote. The reply is a signal on a request path derived from this connection's own name,
/// subscribed before the call so a fast answer is never missed.
final class ScreenGrab: @unchecked Sendable {
    static let shared = ScreenGrab()

    enum Outcome: Sendable {
        case picture(PendingAttachment)
        case cancelled
        case failed(String)
    }

    private let portalBus = "org.freedesktop.portal.Desktop"
    private let portalPath = "/org/freedesktop/portal/desktop"
    private let portalInterface = "org.freedesktop.portal.Screenshot"
    private var bus: OpaquePointer?
    private var probed: Bool?
    private var tokenCounter = 0
    private var subscription: UInt32?

    /// Whether this session has a portal that takes screenshots at all. Asked once: the answer is
    /// the desktop's, and it does not change while the app runs.
    var isAvailable: Bool {
        if let probed { return probed }
        let answer = DesktopGuard.mayClaimMachineKeys && connect() != nil && version() != nil
        probed = answer
        return answer
    }

    /// Hands the drag to the desktop and calls back on the main loop with the picture, or with
    /// why there is none.
    func grab(then done: @escaping @Sendable (Outcome) -> Void) {
        guard let bus = connect(), version() != nil else {
            done(.failed(Localized.text("This desktop has no screenshot portal to drag with.")))
            return
        }
        tokenCounter += 1
        let token = "tailscodegrab\(tokenCounter)"
        guard let unique = g_dbus_connection_get_unique_name(bus) else {
            done(.failed(Localized.text("The screenshot portal did not answer.")))
            return
        }
        let sender = String(cString: unique).dropFirst().replacingOccurrences(of: ".", with: "_")
        let path = "\(portalPath)/request/\(sender)/\(token)"
        let box = ReplyBox { [weak self] parameters in
            self?.unsubscribe()
            done(Self.outcome(of: parameters))
        }
        subscription = g_dbus_connection_signal_subscribe(
            bus, portalBus, "org.freedesktop.portal.Request", "Response", path, nil,
            GDBusSignalFlags(rawValue: 0), Self.signalCallback,
            Unmanaged.passRetained(box).toOpaque(), Self.signalRelease)
        let options = variantDictionary([
            "handle_token": g_variant_new_string(token),
            "interactive": g_variant_new_boolean(1),
            "modal": g_variant_new_boolean(1),
        ])
        var error: UnsafeMutablePointer<GError>?
        let reply = g_dbus_connection_call_sync(
            bus, portalBus, portalPath, portalInterface, "Screenshot",
            variantTuple([g_variant_new_string(""), options]), nil, GDBusCallFlags(rawValue: 0),
            10000, nil, &error)
        if let reply { g_variant_unref(reply) }
        if let error {
            let message = error.pointee.message.map { String(cString: $0) } ?? ""
            g_error_free(error)
            unsubscribe()
            done(.failed(Localized.text("The screenshot portal refused: %@", message)))
        }
    }

    private func unsubscribe() {
        guard let bus, let subscription else { return }
        g_dbus_connection_signal_unsubscribe(bus, subscription)
        self.subscription = nil
    }

    private func connect() -> OpaquePointer? {
        if let bus { return bus }
        var error: UnsafeMutablePointer<GError>?
        bus = g_bus_get_sync(G_BUS_TYPE_SESSION, nil, &error)
        if let error { g_error_free(error) }
        return bus
    }

    private func version() -> UInt32? {
        guard let bus else { return nil }
        var error: UnsafeMutablePointer<GError>?
        let reply = g_dbus_connection_call_sync(
            bus, portalBus, portalPath, "org.freedesktop.DBus.Properties", "Get",
            variantTuple([g_variant_new_string(portalInterface), g_variant_new_string("version")]),
            nil, GDBusCallFlags(rawValue: 0), 3000, nil, &error)
        if let error {
            g_error_free(error)
            return nil
        }
        guard let reply else { return nil }
        defer { g_variant_unref(reply) }
        guard let boxed = g_variant_get_child_value(reply, 0) else { return nil }
        defer { g_variant_unref(boxed) }
        guard let inner = g_variant_get_variant(boxed) else { return nil }
        defer { g_variant_unref(inner) }
        return g_variant_get_uint32(inner)
    }

    /// `0` is a picture, `1` a drag the person called off, anything else the desktop failing.
    private static func outcome(of parameters: OpaquePointer?) -> Outcome {
        guard let parameters,
            let code = g_variant_get_child_value(parameters, 0),
            let results = g_variant_get_child_value(parameters, 1)
        else { return .failed(Localized.text("The screenshot portal did not answer.")) }
        defer {
            g_variant_unref(code)
            g_variant_unref(results)
        }
        switch g_variant_get_uint32(code) {
        case 0: break
        case 1: return .cancelled
        default: return .failed(Localized.text("The desktop could not take the screenshot."))
        }
        guard let value = g_variant_lookup_value(results, "uri", nil) else {
            return .failed(Localized.text("The desktop could not take the screenshot."))
        }
        defer { g_variant_unref(value) }
        guard let raw = g_variant_get_string(value, nil),
            let url = URL(string: String(cString: raw)), url.isFileURL
        else { return .failed(Localized.text("The desktop could not take the screenshot.")) }
        switch AttachmentIntake.read(path: url.path) {
        case .success(let attachment): return .picture(attachment)
        case .failure(let refusal): return .failed(refusal.message)
        }
    }

    private final class ReplyBox {
        let handle: (OpaquePointer?) -> Void
        init(_ handle: @escaping (OpaquePointer?) -> Void) { self.handle = handle }
    }

    private static let signalCallback:
        @convention(c) (
            OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
            UnsafePointer<CChar>?, OpaquePointer?, UnsafeMutableRawPointer?
        ) -> Void = { _, _, _, _, _, parameters, data in
            guard let data else { return }
            Unmanaged<ReplyBox>.fromOpaque(data).takeUnretainedValue().handle(parameters)
        }

    private static let signalRelease: @convention(c) (UnsafeMutableRawPointer?) -> Void = { data in
        guard let data else { return }
        Unmanaged<ReplyBox>.fromOpaque(data).release()
    }
}
