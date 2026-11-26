import Foundation
import Security

/// Pairing tokens shared by the main app and trusted extensions.
///
/// The access group is deliberately explicit on every operation. Omitting
/// `kSecAttrAccessGroup` silently selects each target's private default group,
/// which would make a token saved by the app invisible to the share extension.
///
/// A free Apple ID profile carries no keychain access group, so every call
/// fails with `errSecMissingEntitlement`. Those failures, and a missing
/// configuration, fall back to `OpenMausLocalTokenStore` so pairing still
/// works in the sandbox even though extensions cannot share the token.
enum OpenMausSharedKeychain {
    private static let service = "com.openmausbot.companion.token"

    static func save(_ token: String, for connectionID: String) throws {
        guard OpenMausSharedConfiguration.usesKeychain else {
            try OpenMausLocalTokenStore.save(token, for: connectionID)
            return
        }
        do {
            let accessGroup = try requiredAccessGroup()
            try save(
                Data(token.utf8),
                for: connectionID,
                accessGroup: accessGroup
            )
        } catch {
            guard isMissingEntitlement(error) else { throw error }
            try OpenMausLocalTokenStore.save(token, for: connectionID)
        }
    }

    /// The stored token: nil only when there genuinely is not one.
    /// Locked keychains throw so callers never turn a temporary inability to
    /// read protected data into an accidental unpair; an unavailable
    /// entitlement instead falls back to the local token file.
    static func token(for connectionID: String) throws -> String? {
        guard OpenMausSharedConfiguration.usesKeychain else {
            return OpenMausLocalTokenStore.token(for: connectionID)
        }
        do {
            let accessGroup = try requiredAccessGroup()
            return try readToken(for: connectionID, accessGroup: accessGroup)
        } catch {
            guard isMissingEntitlement(error) else { throw error }
            return OpenMausLocalTokenStore.token(for: connectionID)
        }
    }

    @discardableResult
    static func remove(_ connectionID: String) -> Bool {
        guard OpenMausSharedConfiguration.usesKeychain else {
            return OpenMausLocalTokenStore.remove(connectionID)
        }
        let fileRemoved = OpenMausLocalTokenStore.remove(connectionID)
        guard let accessGroup = OpenMausSharedConfiguration.keychainAccessGroup else {
            return fileRemoved
        }
        return remove(connectionID, accessGroup: accessGroup) && fileRemoved
    }

    /// Main-app upgrade path from the previous app-private keychain item.
    ///
    /// The legacy item is deleted only after the shared item commits, so a
    /// locked keychain leaves the old token untouched and keeps its
    /// locked-vs-missing meaning. An unavailable entitlement is instead
    /// treated as "no legacy item" rather than an error, so a token already
    /// living in the local file store is still used.
    static func tokenMigratingLegacyItem(for connectionID: String) throws -> String? {
        guard OpenMausSharedConfiguration.usesKeychain else {
            return OpenMausLocalTokenStore.token(for: connectionID)
        }
        if let shared = try token(for: connectionID) { return shared }
        let legacyGroup: String
        do {
            legacyGroup = try requiredLegacyAccessGroup()
        } catch {
            guard isMissingEntitlement(error) else { throw error }
            return nil
        }
        let legacy: String?
        do {
            legacy = try readToken(for: connectionID, accessGroup: legacyGroup)
        } catch {
            guard isMissingEntitlement(error) else { throw error }
            legacy = nil
        }
        guard let legacy else { return nil }
        try save(legacy, for: connectionID)
        _ = remove(connectionID, accessGroup: legacyGroup)
        return legacy
    }

    /// Remove both generations when called by the main app. Deleting the
    /// legacy item as well prevents an interrupted earlier migration from
    /// reviving a pairing the user explicitly forgot.
    @discardableResult
    static func removeIncludingLegacyItem(_ connectionID: String) -> Bool {
        guard OpenMausSharedConfiguration.usesKeychain else {
            return remove(connectionID)
        }
        let sharedRemoved = remove(connectionID)
        guard let legacyGroup = OpenMausSharedConfiguration.legacyAppKeychainAccessGroup else {
            return sharedRemoved
        }
        let legacyRemoved = remove(connectionID, accessGroup: legacyGroup)
        return sharedRemoved && legacyRemoved
    }

    /// A free Apple ID profile has no keychain-access-groups entitlement, so
    /// every `SecItem` call is refused before it can look at the item itself.
    private static func isMissingEntitlement(_ error: Error) -> Bool {
        guard let keychainError = error as? OpenMausSharedKeychainError else {
            return false
        }
        switch keychainError {
        case .configurationMissing:
            return true
        case let .security(status):
            return status == errSecMissingEntitlement
        }
    }

    private static func requiredAccessGroup() throws -> String {
        guard let accessGroup = OpenMausSharedConfiguration.keychainAccessGroup else {
            throw OpenMausSharedKeychainError.configurationMissing
        }
        return accessGroup
    }

    private static func requiredLegacyAccessGroup() throws -> String {
        guard let accessGroup = OpenMausSharedConfiguration.legacyAppKeychainAccessGroup else {
            throw OpenMausSharedKeychainError.configurationMissing
        }
        return accessGroup
    }

    private static func identity(
        for connectionID: String,
        accessGroup: String?
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: connectionID,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private static func save(
        _ data: Data,
        for connectionID: String,
        accessGroup: String
    ) throws {
        let itemIdentity = identity(for: connectionID, accessGroup: accessGroup)
        var query = itemIdentity
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        // Add first, then atomically update a duplicate. Delete-then-add can
        // lose the working credential when the second operation is denied.
        var status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(
                itemIdentity as CFDictionary,
                [
                    kSecValueData as String: data,
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                ] as CFDictionary
            )
            if status == errSecItemNotFound {
                status = SecItemAdd(query as CFDictionary, nil)
            }
        }
        guard status == errSecSuccess else {
            throw OpenMausSharedKeychainError.security(status)
        }
    }

    private static func readToken(
        for connectionID: String,
        accessGroup: String?
    ) throws -> String? {
        var query = identity(for: connectionID, accessGroup: accessGroup)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw OpenMausSharedKeychainError.security(status)
        }
        guard let data = item as? Data,
              let token = String(data: data, encoding: .utf8) else {
            throw OpenMausSharedKeychainError.security(errSecDecode)
        }
        return token
    }

    private static func remove(
        _ connectionID: String,
        accessGroup: String?
    ) -> Bool {
        let status = SecItemDelete(
            identity(for: connectionID, accessGroup: accessGroup) as CFDictionary
        )
        // A missing entitlement means no item can exist in that group, so
        // there is nothing left to delete rather than a failed deletion.
        return status == errSecSuccess
            || status == errSecItemNotFound
            || status == errSecMissingEntitlement
    }
}

enum OpenMausSharedKeychainError: LocalizedError {
    case configurationMissing
    case security(OSStatus)

    var errorDescription: String? {
        switch self {
        case .configurationMissing:
            return "Couldn't access the pairing securely: the shared keychain is not configured."
        case let .security(status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            return "Couldn't access the pairing securely: \(detail)"
        }
    }

    /// The keychain is unavailable *yet* rather than missing this token.
    var isLocked: Bool {
        if case let .security(status) = self {
            return status == errSecInteractionNotAllowed
        }
        return false
    }
}
