import Foundation

/// Translates between a device's own names — profile ids it minted for itself — and the ledger's,
/// which every device shares. A conversation is "that server's session", and what counts as that
/// server is its endpoint as ``CloudKeys`` spells it, unless this device has learned that another
/// device spells the same machine differently (an address where this one typed a name).
@MainActor
struct CloudKeyMapper {
    let servers: [CloudServer]
    let aliases: [String: String]

    private func endpoint(of server: CloudServer) -> String {
        aliases[server.endpoint] ?? server.endpoint
    }

    private func server(forProfile id: String) -> CloudServer? {
        servers.first { $0.profileID == id }
    }

    private func server(forEndpoint endpoint: String) -> CloudServer? {
        servers.first { self.endpoint(of: $0) == endpoint }
    }

    private func ledgerKey(profileID: String, sessionID: String) -> String? {
        server(forProfile: profileID).map {
            CloudKeys.conversation(endpoint: endpoint(of: $0), sessionID: sessionID)
        }
    }

    private func ledgerKey(localKey: String) -> String? {
        guard let slash = localKey.firstIndex(of: "/") else { return nil }
        return ledgerKey(
            profileID: String(localKey[..<slash]),
            sessionID: String(localKey[localKey.index(after: slash)...]))
    }

    private func localKey(forLedgerKey key: String) -> String? {
        guard let parts = CloudKeys.split(key), let server = server(forEndpoint: parts.endpoint)
        else { return nil }
        return "\(server.profileID)/\(parts.sessionID)"
    }

    /// What a device agreed on last time, narrowed to the servers it still has. A server that is
    /// gone from this device is not a decision to forget its chats everywhere; only what the
    /// device could still see and no longer does is something the person took away.
    func resolvable(_ local: CloudLocal) -> CloudLocal {
        func held(_ key: String) -> Bool {
            CloudKeys.split(key).map { server(forEndpoint: $0.endpoint) != nil } ?? false
        }
        var out = local
        out.saved = local.saved.filter { held($0.key) }
        out.pinned = local.pinned.filter(held)
        out.archived = local.archived.filter(held)
        return out
    }

    func local(from device: CloudDevice) -> CloudLocal {
        var out = CloudLocal()
        out.seen = device.seenMarks()
        for chat in device.savedChats() {
            guard let key = ledgerKey(profileID: chat.profileID, sessionID: chat.sessionID),
                let server = server(forProfile: chat.profileID)
            else { continue }
            out.saved[key] = CloudChat(
                serverName: server.name, backend: chat.backend, title: chat.title,
                directory: chat.directory, updatedAt: chat.updatedAt.timeIntervalSince1970,
                savedAt: chat.savedAt.timeIntervalSince1970)
        }
        out.pinned = device.pinnedKeys().compactMap(ledgerKey(localKey:))
        out.archived = Set(device.archivedKeys().compactMap(ledgerKey(localKey:)))
        return out
    }

    func apply(_ patch: CloudPatch, to device: CloudDevice) {
        if !patch.seen.isEmpty { device.adoptSeen(patch.seen) }
        applySaved(patch, to: device)
        applyPins(patch, to: device)
        let add = Set(patch.archiveAdds.compactMap(localKey(forLedgerKey:)))
        let remove = Set(patch.archiveRemoves.compactMap(localKey(forLedgerKey:)))
        if !add.isEmpty || !remove.isEmpty { device.adoptArchived(add: add, remove: remove) }
    }

    private func applySaved(_ patch: CloudPatch, to device: CloudDevice) {
        var adds: [SavedChat] = []
        for (key, chat) in patch.saveAdds {
            guard let parts = CloudKeys.split(key), let server = server(forEndpoint: parts.endpoint)
            else { continue }
            adds.append(
                SavedChat(
                    profileID: server.profileID, sessionID: parts.sessionID, title: chat.title,
                    profileName: server.name, backend: chat.backend, directory: chat.directory,
                    updatedAt: Date(timeIntervalSince1970: chat.updatedAt),
                    savedAt: Date(timeIntervalSince1970: chat.savedAt)))
        }
        var removes: [(profileID: String, sessionID: String)] = []
        for key in patch.saveRemoves {
            guard let parts = CloudKeys.split(key), let server = server(forEndpoint: parts.endpoint)
            else { continue }
            removes.append((server.profileID, parts.sessionID))
        }
        if !adds.isEmpty || !removes.isEmpty { device.adoptSaved(add: adds, remove: removes) }
    }

    private func applyPins(_ patch: CloudPatch, to device: CloudDevice) {
        let wanted = patch.pinOrder.compactMap(localKey(forLedgerKey:))
        let removed = Set(patch.pinRemoves.compactMap(localKey(forLedgerKey:)))
        let wantedSet = Set(wanted)
        let strays = device.pinnedKeys().filter { !wantedSet.contains($0) && !removed.contains($0) }
        let order = wanted + strays
        if order != device.pinnedKeys() { device.adoptPins(order: order) }
    }

    /// Finds the servers this device knows by one spelling and the cloud by another. A conversation
    /// the cloud keeps under an endpoint no profile here answers to is matched by what it says
    /// about its server — its name and its kind of agent — and only when that picks out exactly
    /// one profile whose own spelling the cloud has never heard.
    static func discoverAliases(
        servers: [CloudServer], existing: [String: String], ledgers: [CloudLedger]
    ) -> [String: String] {
        let used = Set(
            ledgers.flatMap { ledger in
                [ledger.saved, ledger.pinned, ledger.archived].flatMap { marks in
                    marks.keys.compactMap { CloudKeys.split($0)?.endpoint }
                }
            })
        let claimed = Set(servers.map { existing[$0.endpoint] ?? $0.endpoint })
        var found: [String: String] = [:]
        var named: [String: [(name: String, backend: String)]] = [:]
        for ledger in ledgers {
            for (key, mark) in ledger.saved {
                guard let endpoint = CloudKeys.split(key)?.endpoint, let chat = mark.chat else {
                    continue
                }
                named[endpoint, default: []].append((chat.serverName, chat.backend.rawValue))
            }
        }
        for endpoint in used.subtracting(claimed).sorted() {
            guard let facts = named[endpoint], let first = facts.first else { continue }
            let candidates = servers.filter {
                existing[$0.endpoint] == nil && found[$0.endpoint] == nil
                    && !used.contains($0.endpoint)
                    && $0.name.lowercased() == first.name.lowercased()
                    && $0.backend.rawValue == first.backend
            }
            if candidates.count == 1, let match = candidates.first {
                found[match.endpoint] = endpoint
            }
        }
        return found
    }
}
