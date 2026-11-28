import Foundation
import os
import Security

// MARK: - The Seam

/// Where a protected book's remembered password is kept (FR41, question 2).
/// A password is a secret that decrypts, so a hash of it would remember
/// nothing: what is kept is the password itself, in this device's Keychain
/// and never in `library.json`, a book's record, or `config.json`.
///
/// One item per book, named by the book's content fingerprint
/// (`Book.md5Hash`), so a second copy of the same file shares it. The seam
/// exists so no test touches the real Keychain: on this Mac an unsigned or
/// ad hoc build would make macOS ask the person for their keychain password
/// (the dialog of November 22, 2026).
protocol CredentialStore: Sendable {
    /// The password remembered for the book with `key`, or nil.
    func password(forBook key: String) -> Secret?

    /// Every remembered password, newest first: tried one after another
    /// before the person is asked, since books from one source often share
    /// a password.
    func rememberedPasswords() -> [Secret]

    /// Remembers `secret` for the book with `key`, replacing any earlier one.
    /// - Returns: Whether it was kept.
    @discardableResult
    func remember(_ secret: Secret, forBook key: String) -> Bool

    /// Forgets the password of the book with `key`.
    func forget(forBook key: String)
}

// MARK: - Which Store the App Uses

/// The credential store this process uses. The app's is the Keychain; a
/// process hosting tests gets an empty in-memory one, so a hosted test can
/// never put up a Keychain prompt, whatever it opens.
enum CredentialStores {
    /// The store in use: the Keychain in the app, memory under hosted tests.
    /// Tests replace it with `use(_:)` and put it back when they finish.
    static var current: any CredentialStore {
        override.withLock { $0 } ?? defaultStore
    }

    /// The store a process starts with.
    private static let defaultStore: any CredentialStore = TextMouthRuntime.current.isHostedTest
        ? InMemoryCredentialStore()
        : KeychainCredentialStore()

    /// The store a test put in place, or nil.
    private static let override = OSAllocatedUnfairLock<(any CredentialStore)?>(initialState: nil)

    /// Puts `store` in use until the returned call is made; nil restores the default.
    @discardableResult
    static func use(_ store: (any CredentialStore)?) -> () -> Void {
        let previous = override.withLock { current -> (any CredentialStore)? in
            let earlier = current
            current = store
            return earlier
        }
        return { override.withLock { $0 = previous } }
    }
}

// MARK: - In Memory

/// A store that keeps its passwords in memory only: the fake of every
/// hosted test, and the store of a process hosting tests.
final class InMemoryCredentialStore: CredentialStore {
    /// The remembered passwords, oldest first, each with its book's key.
    private let items = OSAllocatedUnfairLock<[(key: String, secret: Secret)]>(initialState: [])

    /// An empty store.
    init() {}

    func password(forBook key: String) -> Secret? {
        items.withLock { $0.last { $0.key == key }?.secret }
    }

    func rememberedPasswords() -> [Secret] {
        items.withLock { $0.reversed().map(\.secret) }
    }

    @discardableResult
    func remember(_ secret: Secret, forBook key: String) -> Bool {
        items.withLock { stored in
            stored.removeAll { $0.key == key }
            stored.append((key, secret))
        }
        return true
    }

    func forget(forBook key: String) {
        items.withLock { stored in stored.removeAll { $0.key == key } }
    }
}

// MARK: - The Keychain

/// This device's Keychain: a generic password item for each book, service
/// "TextMouth Book Password", kept only while the device is unlocked and
/// never synced (`kSecAttrSynchronizable` false): iCloud Keychain would need
/// the signing a paid team gives, and a remembered password is this
/// device's alone (FR41).
///
/// On the iPhone `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` keeps an item
/// off other devices. On the Mac the item goes in the login (file-based)
/// keychain, which ignores that setting: the item stays this Mac's because
/// iCloud Keychain is not asked for it (`kSecAttrSynchronizable` false), not
/// because the setting holds. The data-protection keychain
/// (`kSecUseDataProtectionKeychain`) would honor it, but needs a keychain
/// access group that the self-signed and ad hoc builds do not have, so it
/// is not used; a build signed by a paid team can switch to it.
///
/// No test calls this type: a signature that changes (ad hoc builds, the
/// trains' builds) makes macOS ask for the keychain password. It is
/// exercised by hand, once, on a signed build.
struct KeychainCredentialStore: CredentialStore {
    /// The service every item carries.
    static let service = "TextMouth Book Password" // l10n: no (the Keychain item's service name, never shown)

    /// The attributes that find the item of the book with `key`.
    private func query(forBook key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: false
        ]
    }

    func password(forBook key: String) -> Secret? {
        var request = query(forBook: key)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return Secret(bytes: [UInt8](data))
    }

    /// The query that lists every item of the service: attributes only.
    /// `SecItemCopyMatching` does not allow `kSecReturnData` with
    /// `kSecMatchLimitAll` for a password item (it answers errSecParam, and
    /// the first version of this code got nothing back), so the data of
    /// each item is fetched on its own (`password(forBook:)`).
    static func listQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
    }

    func rememberedPasswords() -> [Secret] {
        var result: CFTypeRef?
        guard SecItemCopyMatching(Self.listQuery() as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        // Newest first, by the date each item was made, then each one's data.
        let dated = items.compactMap { item -> (Date, String)? in
            guard let account = item[kSecAttrAccount as String] as? String else { return nil }
            return (item[kSecAttrCreationDate as String] as? Date ?? .distantPast, account)
        }
        var unique: [Secret] = []
        for (_, account) in dated.sorted(by: { $0.0 > $1.0 }) {
            guard let secret = password(forBook: account), !unique.contains(secret) else { continue }
            unique.append(secret)
        }
        return unique
    }

    @discardableResult
    func remember(_ secret: Secret, forBook key: String) -> Bool {
        forget(forBook: key)
        var item = query(forBook: key)
        item[kSecValueData as String] = Data(secret.bytes)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    func forget(forBook key: String) {
        SecItemDelete(query(forBook: key) as CFDictionary)
    }
}
