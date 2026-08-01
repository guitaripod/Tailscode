import CodingAgentKit
import CodingAgentKitApple
import Foundation

/// Where a Linux desktop keeps a server's password.
///
/// Secret Service is the right home for it, and it is also absent on a tty, over ssh, and on any
/// session without a keyring daemon — which is a meaningful slice of the audience this app is for.
/// Refusing to run there would be worse than the trade, so the file store is a real fallback with
/// 0600 permissions, and the app is expected to say which of the two it is using rather than
/// pretend they are the same thing.
public struct FileSecretStore: SecretStore, Sendable {
    public enum Backing: String, Sendable {
        case file
    }

    public let backing = Backing.file
    private let url: URL

    public init(url: URL? = nil) {
        self.url = url ?? XDG.dataDirectory.appendingPathComponent("secrets.json")
    }

    public func value(for key: String) throws -> String? {
        try load()[key]
    }

    public func setValue(_ value: String, for key: String) throws {
        var all = try load()
        all[key] = value
        try write(all)
    }

    public func removeValue(for key: String) throws {
        var all = try load()
        all[key] = nil
        try write(all)
    }

    private func load() throws -> [String: String] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private func write(_ all: [String: String]) throws {
        try XDG.ensureDataDirectory()
        let data = try JSONEncoder().encode(all)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Profiles on Linux: the same `ConnectionProfile` the Kit already defines, in the same JSON, but
/// under `$XDG_DATA_HOME` with the password held by a ``SecretStore`` rather than the Keychain.
public struct LinuxProfileStore: Sendable {
    private let secrets: any SecretStore
    private let url: URL

    public init(secrets: any SecretStore = FileSecretStore(), url: URL? = nil) {
        self.secrets = secrets
        self.url = url ?? XDG.dataDirectory.appendingPathComponent("profiles.json")
    }

    public func profiles() throws -> [ConnectionProfile] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return try JSONDecoder().decode([ConnectionProfile].self, from: data)
    }

    public func save(_ profile: ConnectionProfile, password: String?) throws {
        var all = try profiles().filter { $0.id != profile.id }
        all.append(profile)
        try XDG.ensureDataDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(all).write(to: url, options: .atomic)
        if let password, !password.isEmpty {
            try secrets.setValue(password, for: profile.id)
        } else {
            try? secrets.removeValue(for: profile.id)
        }
    }

    public func delete(id: String) throws {
        let remaining = try profiles().filter { $0.id != id }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(remaining).write(to: url, options: .atomic)
        try? secrets.removeValue(for: id)
    }

    public func password(for id: String) throws -> String? {
        try secrets.value(for: id)
    }

    public func makeBackend(_ profile: ConnectionProfile) throws -> any CodingAgentBackend {
        profile.makeBackend(password: try password(for: profile.id))
    }
}

public enum XDG {
    public static var dataDirectory: URL {
        let base = ProcessInfo.processInfo.environment["XDG_DATA_HOME"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/share", isDirectory: true)
        return base.appendingPathComponent("tailscode", isDirectory: true)
    }

    public static func ensureDataDirectory() throws {
        try FileManager.default.createDirectory(
            at: dataDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }
}
