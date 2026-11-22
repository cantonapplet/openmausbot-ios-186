import CryptoKit
import Foundation

/// Sandbox file fallback for pairing tokens.
///
/// Builds signed with a free Apple ID carry no `keychain-access-groups`
/// entitlement, so every access-group query is refused with
/// `errSecMissingEntitlement`. Keeping a copy in Application Support lets
/// pairing succeed there, while the keychain stays the preferred store
/// whenever the entitlement is present.
enum OpenMausLocalTokenStore {
    private static let directoryName = "MausPairingTokens"

    /// Returns false when the token could not be written, so the caller can
    /// rethrow the keychain error instead of reporting a false success.
    static func save(_ token: String, for connectionID: String) -> Bool {
        guard let url = fileURL(for: connectionID) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(token.utf8).write(
                to: url,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            return true
        } catch {
            return false
        }
    }

    static func token(for connectionID: String) -> String? {
        guard let url = fileURL(for: connectionID),
              let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// True when the file is gone: removal stays idempotent, and a missing
    /// file is not a failure worth reporting to the caller.
    @discardableResult
    static func remove(_ connectionID: String) -> Bool {
        guard let url = fileURL(for: connectionID) else { return false }
        try? FileManager.default.removeItem(at: url)
        return !FileManager.default.fileExists(atPath: url.path)
    }

    /// Hashing the identifier keeps arbitrary connection ids valid as
    /// filenames and keeps pairing details out of the directory listing.
    private static func fileURL(for connectionID: String) -> URL? {
        guard let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let digest = SHA256.hash(data: Data(connectionID.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent("\(name).token", isDirectory: false)
    }
}
