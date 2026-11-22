import Foundation
import Security

/// Pairing tokens shared by the main app and trusted extensions.
///
/// The access group is deliberately explicit on every operation. Omitting
/// `kSecAttrAccessGroup` silently selects each target's private default group,
/// which would make a token saved by the app invisible to the share extension.
///
/// Builds signed without that entitlement cannot use any access group at all,
/// so those operations fall back to `OpenMausLocalTokenStore` rather than
/// failing pairing outright.
enum OpenMausSharedKeychain {
    private static let service = "com.openmausbot.companion.token"

    static func save(_ token: String, for connectionID: String) throws {
        do {
            let accessGroup = try requiredAccessGroup()
            try save(
                Data(token.utf8),
                for: connectionID,
                accessGroup: accessGroup
            )
        } catch let error as OpenMausSharedKeychainError where error.isEntitlementUnavailable {
            guard OpenMausLocalTokenStore.save(token, for: connectionID) else {
                throw error
            }
        }
    }

    /// The stored token: nil only when there genuinely is not one.
    /// Locked or misconfigured keychains throw so callers never turn a
    /// temporary inability to read protected data into an accidental unpair;
    /// a build without the access-group entitlement reads the sandbox file.
    static func token(for connectionID: String) throws -> String? {
        do {
            let accessGroup = try requiredAccessGroup()
            return try readToken(for: connectionID, accessGroup: accessGroup)
        } catch let error as OpenMausSharedKeychainError where error.isEntitlementUnavailable {
            return OpenMausLocalTokenStore.token(for: connectionID)
        }
    }

    @discardableResult
    static func remove(_ connectionID: String) -> Bool {
        let fileRemoved = OpenMausLocalTokenStore.remove(connectionID)
        guard let accessGroup = OpenMausSharedConfiguration.keychainAccessGroup else {
            return fileRemoved
        }
        return remove(connectionID, accessGroup: accessGroup) || fileRemoved
    }

    /// Main-app upgrade path from the previous app-private keychain item.
    ///
    /// The legacy item is deleted only after the shared item commits. If the
    /// phone is locked, the old token remains untouched and the error keeps its
    /// locked-vs-missing meaning; a missing entitlement simply reads as nil.
    static func tokenMigratingLegacyItem(for connectionID: String) throws -> String? {
        if let shared = try token(for: connectionID) { return shared }
        // Without the shared entitlement the legacy group is refused as well,
        // so a file already counts as the migrated copy.
        if let local = OpenMausLocalTokenStore.token(for: connectionID) { return local }
        guard let legacyGroup = try? requiredLegacyAccessGroup() else { return nil }
        let legacy: String?
        do {
            legacy = try readToken(for: connectionID, accessGroup: legacyGroup)
        } catch let error as OpenMausSharedKeychainError where error.isEntitlementUnavailable {
            return nil
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
        let sharedRemoved = remove(connectionID)
        guard let legacyGroup = OpenMausSharedConfiguration.legacyAppKeychainAccessGroup else {
            return sharedRemoved
        }
        let legacyRemoved = remove(connectionID, accessGroup: legacyGroup)
        return sharedRemoved && legacyRemoved
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
        return status == errSecSuccess || status == errSecItemNotFound
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

    /// The build is signed without the access group, so the keychain refuses
    /// the request outright and a sandbox file has to take over.
    var isEntitlementUnavailable: Bool {
        switch self {
        case .configurationMissing:
            return true
        case let .security(status):
            return status == errSecMissingEntitlement
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
