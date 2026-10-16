import Foundation

/// What a preview pane is pointed at: an app folder on a Mac that runs a preview host, and the
/// device to run it on. It is stored as one address, so a layout snapshot keeps it the way it
/// keeps a page or a stream, and a restart reopens the pane on the same app and the same Mac.
public struct PreviewTarget: Sendable, Equatable, Hashable {
    public var host: String
    public var port: Int
    public var project: String
    public var deviceType: String?
    public var screen: String?

    public init(
        host: String, port: Int = 4300, project: String, deviceType: String? = nil, screen: String? = nil
    ) {
        self.host = host
        self.port = port
        self.project = project
        self.deviceType = deviceType
        self.screen = screen
    }

    public static let scheme = "preview"

    /// The address a layout snapshot keeps. Reads back to exactly this target.
    public var address: String {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = host
        components.port = port
        components.path = "/"
        var items = [URLQueryItem(name: "project", value: project)]
        if let deviceType { items.append(URLQueryItem(name: "device", value: deviceType)) }
        if let screen { items.append(URLQueryItem(name: "screen", value: screen)) }
        components.queryItems = items
        return components.string ?? "\(Self.scheme)://\(host):\(port)/"
    }

    /// Reads an address back. Anything that is not one of ours, or names no app, is no target, so a
    /// snapshot written by a newer build decodes as an empty pane rather than a wrong one.
    public static func read(_ address: String) -> PreviewTarget? {
        guard let components = URLComponents(string: address), components.scheme == scheme,
            let host = components.host, !host.isEmpty
        else { return nil }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let project = value("project") else { return nil }
        return PreviewTarget(
            host: host, port: components.port ?? 4300, project: project, deviceType: value("device"),
            screen: value("screen"))
    }

    /// The app's folder name, which is what a person calls it.
    public var appName: String {
        let name = (project as NSString).lastPathComponent
        return name.isEmpty ? project : name
    }

    public var label: String { Localized.text("%@ on %@", appName, host) }

    public var access: PreviewAccess { PreviewAccess(host: host, port: port) }
}
