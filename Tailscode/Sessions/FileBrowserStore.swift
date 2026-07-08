import Foundation

enum FileBrowserFavorites {
    private static func key(for profileID: String) -> String {
        "tailscode.favorites.\(profileID)"
    }

    static func all(for profileID: String) -> [String] {
        UserDefaults.standard.stringArray(forKey: key(for: profileID)) ?? []
    }

    static func add(_ path: String, for profileID: String) {
        var favorites = all(for: profileID)
        favorites.removeAll { $0 == path }
        favorites.insert(path, at: 0)
        UserDefaults.standard.set(favorites, forKey: key(for: profileID))
    }

    static func remove(_ path: String, for profileID: String) {
        var favorites = all(for: profileID)
        favorites.removeAll { $0 == path }
        UserDefaults.standard.set(favorites, forKey: key(for: profileID))
    }

    static func toggle(_ path: String, for profileID: String) -> Bool {
        let favorites = all(for: profileID)
        if favorites.contains(path) {
            remove(path, for: profileID)
            return false
        } else {
            add(path, for: profileID)
            return true
        }
    }

    static func isFavorite(_ path: String, for profileID: String) -> Bool {
        all(for: profileID).contains(path)
    }
}

enum FileBrowserRecents {
    private static func key(for profileID: String) -> String {
        "tailscode.recents.\(profileID)"
    }

    static func all(for profileID: String) -> [String] {
        UserDefaults.standard.stringArray(forKey: key(for: profileID)) ?? []
    }

    static func record(_ path: String, for profileID: String) {
        var recents = all(for: profileID)
        recents.removeAll { $0 == path }
        recents.insert(path, at: 0)
        if recents.count > 20 { recents = Array(recents.prefix(20)) }
        UserDefaults.standard.set(recents, forKey: key(for: profileID))
    }
}
