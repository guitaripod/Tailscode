import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The key taken from the whole session rather than from this app's window.
///
/// A Wayland client cannot grab a key: the compositor owns every keystroke, and the only way to be
/// told about one that was pressed somewhere else is to ask the desktop's own portal for it and be
/// granted it by name. That is a conversation rather than a call — a session, a bind, and two
/// replies that arrive as signals — so what this holds is not a boolean but the last thing the
/// desktop actually said, which is the difference between a chord that works and a chord that
/// silently does nothing.
final class Summon: @unchecked Sendable {
    static let shared = Summon()

    static let didChange = Notification.Name("tailscode.linux.summon.didChange")

    private let portalBus = "org.freedesktop.portal.Desktop"
    private let portalPath = "/org/freedesktop/portal/desktop"
    private let portalInterface = "org.freedesktop.portal.GlobalShortcuts"
    /// The shortcut's name carries the chord it was asked for. A desktop that remembers what it
    /// granted a name — KDE does — hands back the old key forever if the name never changes, so a
    /// person who picks a new chord in this app is told the old one is still theirs. A new chord is
    /// a new name, which is a question the desktop has not already answered.
    private func shortcutID(for chord: SummonChord) -> String { shortcutFamily + chord.spec }
    private let shortcutFamily = "quick-ask-"

    private var bus: OpaquePointer?
    private var sessionHandle: String?
    private var handler: (@Sendable () -> Void)?
    private var activationSubscription: UInt32?
    private var changeSubscription: UInt32?
    private var tokenCounter = 0
    private var attempt = 0
    private var releasedFormerGrants = false
    private var filledEmptyGrant = false

    private(set) var state: SummonState = .off

    var desktop: SummonDesktop { SummonDesktop.detect() }

    /// The line this desktop would need in its own config to reach a Tailscode that is not
    /// running. Offered beside whatever the portal managed, because the two answer different
    /// mornings.
    var recipe: SummonRecipe {
        SummonRecipe.make(
            chord: SummonSettings.chord, desktop: desktop, command: "\(Self.command) --ask")
    }

    private static var command: String {
        let path = Arguments.all.first ?? "tailscode"
        return path.hasPrefix("/") && !path.contains("/.build/") ? path : "tailscode"
    }

    func start(onSummon: @escaping @Sendable () -> Void) {
        handler = onSummon
        refresh()
    }

    /// Asks again from nothing: the desktop is told to forget the old chord before it is told the
    /// new one, because a portal session left open keeps the key it was granted.
    func refresh() {
        SettingsFile.capture()
        filledEmptyGrant = false
        closeSession()
        guard SummonSettings.isEnabled else {
            publish(.off)
            return
        }
        let chord = SummonSettings.chord
        if case .refused(let reason) = SummonJudge.judge(chord, on: .linux) {
            publish(.unavailable(reason))
            return
        }
        attempt += 1
        let round = attempt
        awaitAnswer(for: chord, round: round)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.connectAndBind(chord)
        }
    }

    /// A desktop that is asking the person whether this app may take a key answers whenever they
    /// do, which can be never. Silence is therefore given a face of its own rather than left to
    /// look like a chord that works: the surface says the key was asked for and not yet granted,
    /// and the real answer replaces it whenever it arrives.
    private func awaitAnswer(for chord: SummonChord, round: Int) {
        Gtk.after(12_000) { [weak self] in
            guard let self, self.attempt == round, !self.state.isLive else { return }
            if case .off = self.state {
                self.publish(.awaiting(chord, where: self.desktop.name))
            }
        }
    }

    /// The state is written on the main context even though it is decided on a background one:
    /// the portal's replies arrive off the main thread, and a settings row that reads a value
    /// another thread wrote without a handoff can read the one before it — which showed as a
    /// bound chord reporting itself as off.
    private func publish(_ next: SummonState) {
        AppLog.write(.ui, "summon \(next.line(on: .linux))")
        Gtk.onMain { [weak self] in
            self?.state = next
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }

    private func connectAndBind(_ chord: SummonChord) {
        var error: UnsafeMutablePointer<GError>?
        if bus == nil {
            bus = g_bus_get_sync(G_BUS_TYPE_SESSION, nil, &error)
        }
        guard let bus else {
            publish(
                .unavailable(
                    Localized.text("This session has no message bus to ask for a key.")))
            if let error { g_error_free(error) }
            return
        }
        guard portalVersion(bus) != nil else {
            publish(.unavailable(SummonObstacle.noPortal(desktop: desktop.name).line))
            return
        }
        releaseGrantsHeldByFormerIdentities(bus)
        let token = nextToken()
        awaitResponse(on: bus, token: token) { [weak self] results in
            self?.sessionCreated(results, chord: chord)
        }
        let options = variantDictionary([
            "handle_token": g_variant_new_string(token),
            "session_handle_token": g_variant_new_string(nextToken()),
        ])
        var refusal: String?
        guard call(bus, method: "CreateSession", arguments: variantTuple([options]), failure: &refusal)
            != nil
        else {
            publish(.unavailable(diagnose(refusal)))
            return
        }
    }

    /// The names this app has answered to before the one it wears now.
    private static let formerIdentities = ["com.guitaripod.tailscode"]

    /// Lets go of the key a former name of this app is still holding.
    ///
    /// A desktop that records a grant against an app id keeps the record long after the app that
    /// earned it stopped existing, and a rename therefore arrives as a chord that is already taken
    /// — by nothing. KDE answers that conflict by registering the shortcut with no key at all, so
    /// the app reports the key as asked for and never granted, forever, and the only cure is the
    /// desktop's own settings. What the old name held is dropped before the new one asks.
    private func releaseGrantsHeldByFormerIdentities(_ bus: OpaquePointer) {
        guard !releasedFormerGrants else { return }
        releasedFormerGrants = true
        for identity in Self.formerIdentities where releaseGrant(heldBy: identity) {
            AppLog.write(.ui, "summon released the key held by \(identity)")
        }
    }

    /// Drops a desktop's record of what it granted an app id, and says whether there was one.
    /// Only KDE keeps such a record; every other desktop answers nothing here, which is the same
    /// answer as having nothing to drop.
    private func releaseGrant(heldBy identity: String) -> Bool {
        guard let bus else { return false }
        let component = String(identity.map { $0.isLetter || $0.isNumber ? $0 : "_" })
        var error: UnsafeMutablePointer<GError>?
        let reply = g_dbus_connection_call_sync(
            bus, "org.kde.kglobalaccel", "/component/\(component)",
            "org.kde.kglobalaccel.Component", "cleanUp", g_variant_new_tuple(nil, 0), nil,
            GDBusCallFlags(rawValue: 1), 2000, nil, &error)
        if let error {
            g_error_free(error)
            return false
        }
        guard let reply else { return false }
        defer { g_variant_unref(reply) }
        guard let removed = g_variant_get_child_value(reply, 0) else { return false }
        defer { g_variant_unref(removed) }
        return g_variant_get_boolean(removed) != 0
    }

    /// A shortcut the desktop wrote down under this app's own name and never gave a key to.
    ///
    /// KDE takes a preferred trigger only the first time it sees a shortcut's name, so a record
    /// written while the chord was held by something else outlives the conflict that caused it:
    /// the name is known, the key is empty, and asking again politely changes nothing for as long
    /// as the app is installed. What its own settings do — assign the key to the record that is
    /// already there — is therefore done directly, once, and only when nothing else answers that
    /// key. Something that does own it is named rather than waited on forever, and a chord
    /// somebody reassigned by hand carries a trigger and never reaches here.
    private func fillEmptyGrant(_ chord: SummonChord) -> Bool {
        guard !filledEmptyGrant, let code = KDEKey.code(for: chord) else { return false }
        filledEmptyGrant = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            if let holder = self.holder(ofKey: code) {
                guard holder.identity != DesktopIntegration.appID else {
                    self.publish(.bound(chord, reach: .whileRunning))
                    return
                }
                self.publish(.taken(chord, by: holder.name))
                return
            }
            self.assign(code, to: chord)
            guard self.holder(ofKey: code)?.identity == DesktopIntegration.appID else {
                self.publish(.awaiting(chord, where: self.desktop.name))
                return
            }
            AppLog.write(.ui, "summon filled an empty grant with \(chord.spec)")
            self.publish(.bound(chord, reach: .whileRunning))
        }
        return true
    }

    /// Whichever component answers a key, by the desktop's own reckoning.
    private func holder(ofKey code: Int32) -> (identity: String, name: String)? {
        guard let bus else { return nil }
        var error: UnsafeMutablePointer<GError>?
        let reply = g_dbus_connection_call_sync(
            bus, "org.kde.kglobalaccel", "/kglobalaccel", "org.kde.KGlobalAccel",
            "getGlobalShortcutsByKey", variantTuple([g_variant_new_int32(code)]), nil,
            GDBusCallFlags(rawValue: 1), 2000, nil, &error)
        if let error {
            g_error_free(error)
            return nil
        }
        guard let reply else { return nil }
        defer { g_variant_unref(reply) }
        guard let rows = g_variant_get_child_value(reply, 0), g_variant_n_children(rows) > 0 else {
            return nil
        }
        defer { g_variant_unref(rows) }
        guard let row = g_variant_get_child_value(rows, 0) else { return nil }
        defer { g_variant_unref(row) }
        guard let identity = text(row, at: 2), let name = text(row, at: 3) else { return nil }
        return (identity, name)
    }

    private func assign(_ code: Int32, to chord: SummonChord) {
        guard let bus else { return }
        let action = variantArray(
            type: "as",
            children: [
                g_variant_new_string(DesktopIntegration.appID),
                g_variant_new_string(shortcutID(for: chord)),
                g_variant_new_string("Tailscode"),
                g_variant_new_string(Localized.text("Ask Tailscode a question")),
            ])
        let keys = variantArray(type: "ai", children: [g_variant_new_int32(code)])
        var error: UnsafeMutablePointer<GError>?
        let reply = g_dbus_connection_call_sync(
            bus, "org.kde.kglobalaccel", "/kglobalaccel", "org.kde.KGlobalAccel",
            "setForeignShortcut", variantTuple([action, keys]), nil, GDBusCallFlags(rawValue: 1),
            2000, nil, &error)
        if let error { g_error_free(error) }
        if let reply { g_variant_unref(reply) }
    }

    private func text(_ variant: OpaquePointer, at index: gsize) -> String? {
        guard let child = g_variant_get_child_value(variant, index) else { return nil }
        defer { g_variant_unref(child) }
        guard let raw = g_variant_get_string(child, nil) else { return nil }
        return String(cString: raw)
    }

    private func sessionCreated(_ results: OpaquePointer?, chord: SummonChord) {
        guard let results, let handle = string(results, key: "session_handle"), let bus else {
            publish(
                .unavailable(Localized.text("%@ opened no shortcuts session.", desktop.name)))
            return
        }
        sessionHandle = handle
        subscribeToActivation(handle)
        let token = nextToken()
        awaitResponse(on: bus, token: token) { [weak self] results in
            self?.shortcutsBound(results, chord: chord)
        }
        let shortcut = variantTuple([
            g_variant_new_string(shortcutID(for: chord)),
            variantDictionary([
                "description": g_variant_new_string(
                    Localized.text("Ask Tailscode a question")),
                "preferred_trigger": g_variant_new_string(chord.portalTrigger),
            ]),
        ])
        let list = variantArray(type: "a(sa{sv})", children: [shortcut])
        let options = variantDictionary(["handle_token": g_variant_new_string(token)])
        let arguments = variantTuple([
            g_variant_new_object_path(handle), list, g_variant_new_string(""), options,
        ])
        var refusal: String?
        guard call(bus, method: "BindShortcuts", arguments: arguments, failure: &refusal) != nil
        else {
            publish(.unavailable(diagnose(refusal)))
            return
        }
    }

    /// What the desktop granted, which is not necessarily what was asked for. An empty trigger is
    /// a shortcut the desktop has taken note of and not yet given a key — the person has to finish
    /// it in the desktop's own settings, and saying "bound" here is exactly the lie this state
    /// exists to prevent.
    private func shortcutsBound(_ results: OpaquePointer?, chord: SummonChord) {
        guard let results, let shortcuts = g_variant_lookup_value(results, "shortcuts", nil) else {
            publish(.awaiting(chord, where: desktop.name))
            return
        }
        defer { g_variant_unref(shortcuts) }
        var trigger: String?
        for index in 0..<g_variant_n_children(shortcuts) {
            guard let entry = g_variant_get_child_value(shortcuts, index) else { continue }
            defer { g_variant_unref(entry) }
            guard let identifier = g_variant_get_child_value(entry, 0),
                let metadata = g_variant_get_child_value(entry, 1)
            else { continue }
            defer {
                g_variant_unref(identifier)
                g_variant_unref(metadata)
            }
            guard let raw = g_variant_get_string(identifier, nil),
                String(cString: raw) == shortcutID(for: chord)
            else { continue }
            if let described = string(metadata, key: "trigger_description"), !described.isEmpty {
                trigger = described
            }
        }
        guard let trigger else {
            if fillEmptyGrant(chord) { return }
            publish(.awaiting(chord, where: desktop.name))
            return
        }
        let asked = chord.display(on: .linux).lowercased()
        let granted = trigger.lowercased().replacingOccurrences(of: "meta", with: "super")
        if granted.contains(asked) || asked.contains(granted) {
            publish(.bound(chord, reach: .whileRunning))
        } else {
            publish(.reassigned(chord, trigger: trigger, reach: .whileRunning))
        }
    }

    private func subscribeToActivation(_ handle: String) {
        guard let bus, activationSubscription == nil else { return }
        activationSubscription = subscribe(bus, member: "Activated") { [weak self] parameters in
            guard let self, let parameters else { return }
            guard let identifier = g_variant_get_child_value(parameters, 1) else { return }
            defer { g_variant_unref(identifier) }
            guard let raw = g_variant_get_string(identifier, nil),
                String(cString: raw).hasPrefix(self.shortcutFamily)
            else { return }
            let handler = self.handler
            Gtk.onMain { handler?() }
        }
        changeSubscription = subscribe(bus, member: "ShortcutsChanged") { [weak self] parameters in
            guard let self, let parameters,
                let shortcuts = g_variant_get_child_value(parameters, 1)
            else { return }
            defer { g_variant_unref(shortcuts) }
            let results = variantDictionary(["shortcuts": g_variant_ref(shortcuts)])
            g_variant_ref_sink(results)
            self.shortcutsBound(results, chord: SummonSettings.chord)
            g_variant_unref(results)
        }
        _ = handle
    }

    private func closeSession() {
        guard let bus, let handle = sessionHandle else { return }
        var error: UnsafeMutablePointer<GError>?
        g_dbus_connection_call_sync(
            bus, portalBus, handle, "org.freedesktop.portal.Session", "Close",
            g_variant_new_tuple(nil, 0), nil, GDBusCallFlags(rawValue: 0), 2000, nil, &error)
        if let error { g_error_free(error) }
        sessionHandle = nil
    }

    private func portalVersion(_ bus: OpaquePointer) -> UInt32? {
        var error: UnsafeMutablePointer<GError>?
        let arguments = variantTuple([
            g_variant_new_string(portalInterface), g_variant_new_string("version"),
        ])
        let reply = g_dbus_connection_call_sync(
            bus, portalBus, portalPath, "org.freedesktop.DBus.Properties", "Get", arguments, nil,
            GDBusCallFlags(rawValue: 0), 5000, nil, &error)
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

    /// What the portal said when it said no. The refusal a desktop gives for a key is the whole
    /// diagnosis — a session that could not be opened at all and one that was opened and left
    /// unbound are different problems with different fixes — so the message is carried out rather
    /// than thrown away with the error.
    private func diagnose(_ refusal: String?) -> String {
        guard let refusal else {
            return Localized.text("%@ refused to grant a key and said no more.", desktop.name)
        }
        if refusal.contains("app id") || refusal.contains("NotAllowed") {
            return SummonObstacle.noAppIdentity(desktop: desktop.name).line
        }
        return refusal
    }

    private func call(
        _ bus: OpaquePointer, method: String, arguments: OpaquePointer?,
        failure: inout String?
    ) -> String? {
        var error: UnsafeMutablePointer<GError>?
        let reply = g_dbus_connection_call_sync(
            bus, portalBus, portalPath, portalInterface, method, arguments, nil,
            GDBusCallFlags(rawValue: 0), 10000, nil, &error)
        if let error {
            if let message = error.pointee.message { failure = String(cString: message) }
            g_error_free(error)
            return nil
        }
        guard let reply else { return nil }
        defer { g_variant_unref(reply) }
        guard let path = g_variant_get_child_value(reply, 0) else { return nil }
        defer { g_variant_unref(path) }
        guard let raw = g_variant_get_string(path, nil) else { return nil }
        return String(cString: raw)
    }

    /// The reply to a portal request arrives as a signal on a path derived from the caller's own
    /// bus name, so the listener is installed before the call rather than after it — a reply that
    /// beats the subscription is a session that never opens and never says why.
    private func awaitResponse(
        on bus: OpaquePointer, token: String, then handle: @escaping (OpaquePointer?) -> Void
    ) {
        guard let unique = g_dbus_connection_get_unique_name(bus) else { return }
        let sender = String(cString: unique).dropFirst().replacingOccurrences(of: ".", with: "_")
        let path = "\(portalPath)/request/\(sender)/\(token)"
        let box = SignalBox { [weak self] parameters in
            guard let self else { return }
            if let subscription = self.pendingSubscriptions[path] {
                g_dbus_connection_signal_unsubscribe(bus, subscription)
                self.pendingSubscriptions[path] = nil
            }
            guard let parameters, let results = g_variant_get_child_value(parameters, 1) else {
                handle(nil)
                return
            }
            defer { g_variant_unref(results) }
            handle(results)
        }
        let identifier = g_dbus_connection_signal_subscribe(
            bus, portalBus, "org.freedesktop.portal.Request", "Response", path, nil,
            GDBusSignalFlags(rawValue: 0), Self.signalCallback,
            Unmanaged.passRetained(box).toOpaque(), Self.signalRelease)
        pendingSubscriptions[path] = identifier
    }

    private var pendingSubscriptions: [String: UInt32] = [:]

    private func subscribe(
        _ bus: OpaquePointer, member: String, handle: @escaping (OpaquePointer?) -> Void
    ) -> UInt32 {
        let box = SignalBox(handle)
        return g_dbus_connection_signal_subscribe(
            bus, portalBus, portalInterface, member, portalPath, nil, GDBusSignalFlags(rawValue: 0),
            Self.signalCallback, Unmanaged.passRetained(box).toOpaque(), Self.signalRelease)
    }

    private final class SignalBox {
        let handle: (OpaquePointer?) -> Void
        init(_ handle: @escaping (OpaquePointer?) -> Void) { self.handle = handle }
    }

    private static let signalCallback:
        @convention(c) (
            OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
            UnsafePointer<CChar>?, OpaquePointer?, UnsafeMutableRawPointer?
        ) -> Void = { _, _, _, _, _, parameters, data in
            guard let data else { return }
            Unmanaged<SignalBox>.fromOpaque(data).takeUnretainedValue().handle(parameters)
        }

    private static let signalRelease: @convention(c) (UnsafeMutableRawPointer?) -> Void = { data in
        guard let data else { return }
        Unmanaged<SignalBox>.fromOpaque(data).release()
    }

    private func nextToken() -> String {
        tokenCounter += 1
        return "tailscode\(tokenCounter)"
    }

    private func string(_ dictionary: OpaquePointer, key: String) -> String? {
        guard let value = g_variant_lookup_value(dictionary, key, nil) else { return nil }
        defer { g_variant_unref(value) }
        guard let raw = g_variant_get_string(value, nil) else { return nil }
        return String(cString: raw)
    }
}

/// What this app can be asked to do by something that is not this app. GApplication exports its
/// own action map on the session bus, so a second launch — or a desktop's own key binding running
/// `tailscode --ask` — reaches the process that already exists rather than starting a rival one.
enum AppActions {
    static func installAsk(on app: UnsafeMutableRawPointer, handle: @escaping @Sendable () -> Void)
    {
        guard let action = g_simple_action_new("ask", nil) else { return }
        let box = Unmanaged.passRetained(ActionBox(handle)).toOpaque()
        let callback:
            @convention(c) (OpaquePointer?, OpaquePointer?, UnsafeMutableRawPointer?) -> Void = {
                _, _, raw in
                guard let raw else { return }
                let handle = Unmanaged<ActionBox>.fromOpaque(raw).takeUnretainedValue().handle
                Gtk.onMain { handle() }
            }
        tailscode_connect(
            UnsafeMutableRawPointer(action), "activate",
            unsafeBitCast(callback, to: GCallback.self), box)
        g_action_map_add_action(op(app), op(UnsafeMutableRawPointer(action)))
    }

    private final class ActionBox: @unchecked Sendable {
        let handle: @Sendable () -> Void
        init(_ handle: @escaping @Sendable () -> Void) { self.handle = handle }
    }
}

/// GVariant's own constructors are variadic, which Swift cannot call at all, so every value this
/// file hands the bus is built out of the handful that are not.
private func variantDictionary(_ entries: [String: OpaquePointer?]) -> OpaquePointer? {
    guard let type = g_variant_type_new("a{sv}") else { return nil }
    defer { g_variant_type_free(type) }
    let builder = g_variant_builder_new(type)
    for (key, value) in entries {
        guard let value else { continue }
        let boxed = g_variant_new_variant(value)
        let entry = g_variant_new_dict_entry(g_variant_new_string(key), boxed)
        g_variant_builder_add_value(builder, entry)
    }
    let result = g_variant_builder_end(builder)
    g_variant_builder_unref(builder)
    return result
}

private func variantTuple(_ children: [OpaquePointer?]) -> OpaquePointer? {
    var values = children
    return values.withUnsafeMutableBufferPointer { buffer in
        g_variant_new_tuple(buffer.baseAddress, gsize(buffer.count))
    }
}

private func variantArray(type: String, children: [OpaquePointer?]) -> OpaquePointer? {
    guard let variantType = g_variant_type_new(type) else { return nil }
    defer { g_variant_type_free(variantType) }
    let builder = g_variant_builder_new(variantType)
    for child in children {
        guard let child else { continue }
        g_variant_builder_add_value(builder, child)
    }
    let result = g_variant_builder_end(builder)
    g_variant_builder_unref(builder)
    return result
}

/// A chord as Qt spells one, which is the only spelling KDE's shortcut registry accepts.
///
/// The portal's own trigger grammar is words; the registry underneath it is a single integer whose
/// high bits are the modifiers. The two are not interchangeable, and a chord this cannot spell is
/// left to the portal rather than guessed at.
private enum KDEKey {
    private static let shift: Int32 = 0x0200_0000
    private static let control: Int32 = 0x0400_0000
    private static let alt: Int32 = 0x0800_0000
    private static let meta: Int32 = 0x1000_0000

    private static let named: [String: Int32] = [
        "space": 0x20, "return": 0x0100_0004, "tab": 0x0100_0001, "escape": 0x0100_0000,
        "left": 0x0100_0012, "up": 0x0100_0013, "right": 0x0100_0014, "down": 0x0100_0015,
        "period": 0x2E, "comma": 0x2C, "slash": 0x2F, "grave": 0x60, "minus": 0x2D,
        "equal": 0x3D,
    ]

    static func code(for chord: SummonChord) -> Int32? {
        guard var code = key(chord.key) else { return nil }
        if chord.control { code |= control }
        if chord.alt { code |= alt }
        if chord.shift { code |= shift }
        if chord.meta { code |= meta }
        return code
    }

    private static func key(_ name: String) -> Int32? {
        if let named = named[name] { return named }
        if name.count == 1, let scalar = name.uppercased().unicodeScalars.first,
            scalar.isASCII, scalar.properties.isAlphabetic || ("0"..."9").contains(name)
        {
            return Int32(scalar.value)
        }
        if name.first == "f", let number = Int32(name.dropFirst()), (1...35).contains(number) {
            return 0x0100_0030 + number - 1
        }
        return nil
    }
}
