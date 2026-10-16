import TailscodeCore

/// Whether a conversation can open a preview, decided in one place so the chat's button and
/// anything that asks later agree. A preview needs two facts the conversation already holds: the
/// machine it talks to has a preview host this device has agreed to use, and the folder the agent
/// works in is known. Either missing, and the entry is not offered at all.
enum PreviewEntry {
    static func target(
        host: String?, directory: String?,
        access: (String) -> PreviewAccess? = { PreviewAccessStore.access(host: $0) }
    ) -> PreviewTarget? {
        guard let host, !host.isEmpty,
            let folder = directory?.trimmingCharacters(in: .whitespacesAndNewlines), !folder.isEmpty,
            let known = access(host)
        else { return nil }
        return PreviewTarget(host: known.host, port: known.port, project: folder)
    }
}
