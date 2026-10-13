import Foundation
import Security

enum Keychain {
    private static let service = "BitbucketPRNotifier"

    static func load(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func save(_ data: Data, account: String) {
        delete(account: account)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// How the user signed in. Stored as JSON in a file only the user can read
/// (like `gh` and `acli`). The Keychain re-prompts after every rebuild of an
/// ad-hoc-signed app, so it's only read once, to migrate older installs.
enum Credentials: Codable {
    case apiToken(email: String, token: String)
    case oauth(OAuthTokens)

    private static let keychainAccount = "credentials"

    private static func fileURL(_ name: String = "credentials") -> URL {
        let folder = TestOverrides.url("BPRN_SUPPORT_DIR") ?? FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/BitbucketPRNotifier")
        return folder.appending(path: "\(name).json")
    }

    /// The API token from before the last sign-out, to fill in the next sign-in.
    static var signedOutToken: String? {
        guard let data = try? Data(contentsOf: fileURL("signed-out")),
              case .apiToken(_, let token) = try? JSONDecoder().decode(Credentials.self, from: data) else { return nil }
        return token
    }

    static func load() -> Credentials? {
        if let data = try? Data(contentsOf: fileURL()) {
            return try? JSONDecoder().decode(Credentials.self, from: data)
        }
        guard let data = Keychain.load(account: keychainAccount),
              let credentials = try? JSONDecoder().decode(Credentials.self, from: data) else { return nil }
        credentials.save()
        Keychain.delete(account: keychainAccount)
        return credentials
    }

    func save(as name: String = "credentials") {
        guard let data = try? JSONEncoder().encode(self) else { return }
        let url = Self.fileURL(name)
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        // Owner-only permissions before writing the secret, even if the file already existed.
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard (try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)) != nil else { return }
        try? data.write(to: url)
    }

    /// Signing out keeps an API token aside (same owner-only file) for next time.
    static func delete() {
        if case .apiToken = load() { load()?.save(as: "signed-out") }
        try? FileManager.default.removeItem(at: fileURL())
    }
}
