import CryptoKit
import Foundation

/// File-backed pairing tokens for builds whose provisioning profile carries
/// no keychain access group.
///
/// A free Apple ID profile has neither keychain-access-groups nor app groups,
/// so every `SecItem` call fails with `errSecMissingEntitlement`. Keeping the
/// token in the app sandbox lets the main app still pair; trusted extensions,
/// which rely on the shared keychain, simply cannot see it.
enum OpenMausLocalTokenStore {
    private static let directoryName = "MausPairingTokens"
    private static let fileExtension = "token"

    /// The token is written atomically as raw UTF-8 bytes behind first-unlock
    /// file protection, matching the keychain's own accessibility.
    static func save(_ token: String, for connectionID: String) throws {
        let fileURL = try fileURL(for: connectionID)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(token.utf8).write(
            to: fileURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    /// nil whenever the file is absent or unreadable: once the keychain has
    /// been ruled out, both mean there is no pairing to restore.
    static func token(for connectionID: String) -> String? {
        guard let fileURL = try? fileURL(for: connectionID),
              let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func remove(_ connectionID: String) -> Bool {
        guard let fileURL = try? fileURL(for: connectionID) else { return false }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return true }
        do {
            try FileManager.default.removeItem(at: fileURL)
            return true
        } catch {
            return false
        }
    }

    /// The connection identifier is hashed so the sandbox filename reveals
    /// nothing about the pairing and no token ever reaches the file name.
    private static func fileName(for connectionID: String) -> String {
        let digest = SHA256.hash(data: Data(connectionID.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(hex).\(fileExtension)"
    }

    private static func fileURL(for connectionID: String) throws -> URL {
        guard let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw OpenMausLocalTokenStoreError.directoryUnavailable
        }
        return directory
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName(for: connectionID), isDirectory: false)
    }
}

enum OpenMausLocalTokenStoreError: LocalizedError {
    case directoryUnavailable

    var errorDescription: String? {
        switch self {
        case .directoryUnavailable:
            return "Couldn't access the pairing securely: the local token store is unavailable."
        }
    }
}
