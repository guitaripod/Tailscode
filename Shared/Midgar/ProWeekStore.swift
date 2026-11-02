import Foundation
import MidgarCore
import Security

/// Where the Pro week is remembered on this device: its start, the servers it lent, the servers the person chose to keep
/// connected, how many servers the free copy keeps afterwards, and whether the end note was shown. The start is also kept
/// in the keychain, because a reinstall would otherwise hand out another week; the item is never synchronizable, so a week
/// belongs to one device. Tests get a store that leaves the keychain alone.
struct ProWeekStore {
    private static let startKey = "tailscode.proWeek.start"
    private static let lentKey = "tailscode.proWeek.lent"
    private static let picksKey = "tailscode.proWeek.picks"
    private static let keepsKey = "tailscode.proWeek.keeps"
    private static let endNoticeKey = "tailscode.proWeek.endNoticeShown"
    private static let keychainService = "com.guitaripod.tailscode.proweek"
    private static let keychainAccount = "start"

    let defaults: UserDefaults
    let usesKeychain: Bool

    static func live(defaults: UserDefaults = .standard) -> ProWeekStore {
        ProWeekStore(defaults: defaults, usesKeychain: true)
    }

    var start: Date? {
        let stored = usesKeychain ? Self.keychainStart() : nil
        guard let seconds = stored ?? (defaults.object(forKey: Self.startKey) as? Double) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    func saveStart(_ date: Date) {
        defaults.set(date.timeIntervalSince1970, forKey: Self.startKey)
        if usesKeychain { Self.writeKeychainStart(date.timeIntervalSince1970) }
    }

    var lent: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.lentKey) ?? []) }
        nonmutating set { defaults.set(newValue.sorted(), forKey: Self.lentKey) }
    }

    var picks: [String] {
        get { defaults.stringArray(forKey: Self.picksKey) ?? [] }
        nonmutating set { defaults.set(newValue, forKey: Self.picksKey) }
    }

    var keeps: Int {
        get { defaults.integer(forKey: Self.keepsKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.keepsKey) }
    }

    var endNoticeShown: Bool {
        get { defaults.bool(forKey: Self.endNoticeKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.endNoticeKey) }
    }

    #if DEBUG
        /// Forgets the week and everything it lent, keychain item included, for debug launches that restage it.
        func reset() {
            for key in [Self.startKey, Self.lentKey, Self.picksKey, Self.keepsKey, Self.endNoticeKey] {
                defaults.removeObject(forKey: key)
            }
            if usesKeychain { SecItemDelete(Self.baseQuery as CFDictionary) }
        }
    #endif

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private static func keychainStart() -> Double? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data,
            let text = String(data: data, encoding: .utf8)
        else { return nil }
        return Double(text)
    }

    /// Adds the item once; a start already stored is never moved.
    private static func writeKeychainStart(_ seconds: Double) {
        var query = baseQuery
        query[kSecValueData as String] = Data(String(seconds).utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess && status != errSecDuplicateItem {
            MidgarLog.notice("Pro week start not written to the keychain: \(status)", category: .commerce)
        }
    }
}
