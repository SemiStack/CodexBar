import CodexBarCore
import Foundation

struct AntigravityOAuthCredential: Codable, Sendable {
    let email: String
    let accessToken: String
    let refreshToken: String
    let accessTokenExpiry: Date
    let updatedAt: Date
}

private struct AntigravityOAuthCredentialEnvelope: Codable, Sendable {
    var credentials: [AntigravityOAuthCredential]
}

private struct AntigravityRemovedAccountEnvelope: Codable, Sendable {
    var emails: [String]
}

enum AntigravityOAuthCredentialStore {
    private static let cacheKey = KeychainCacheStore.Key(category: "oauth", identifier: "antigravity.accounts")
    private static let removedAccountsFileName = "antigravity-removed-oauth-accounts.json"

    static func allCredentials() -> [AntigravityOAuthCredential] {
        let credentials: [AntigravityOAuthCredential] = switch KeychainCacheStore.load(
            key: self.cacheKey,
            as: AntigravityOAuthCredentialEnvelope.self)
        {
        case let .found(entry):
            self.normalized(entry.credentials)
        case .missing, .invalid:
            []
        }

        let removed = self.removedEmails()
        guard !removed.isEmpty else {
            return credentials
        }
        return credentials.filter { !removed.contains($0.email) }
    }

    static func credential(for email: String) -> AntigravityOAuthCredential? {
        let normalizedEmail = self.normalizeEmail(email)
        return self.allCredentials().first(where: { $0.email == normalizedEmail })
    }

    static func upsert(_ credential: AntigravityOAuthCredential) {
        let normalizedCredential = AntigravityOAuthCredential(
            email: self.normalizeEmail(credential.email),
            accessToken: credential.accessToken,
            refreshToken: credential.refreshToken,
            accessTokenExpiry: credential.accessTokenExpiry,
            updatedAt: credential.updatedAt)
        var current = self.credentialsFromKeychain().filter { $0.email != normalizedCredential.email }
        current.append(normalizedCredential)
        self.removeRemovedEmail(normalizedCredential.email)
        KeychainCacheStore.store(
            key: self.cacheKey,
            entry: AntigravityOAuthCredentialEnvelope(credentials: self.normalized(current)))
    }

    static func remove(email: String) {
        let normalizedEmail = self.normalizeEmail(email)
        guard !normalizedEmail.isEmpty else { return }
        var removed = self.removedEmails()
        removed.insert(normalizedEmail)
        self.persistRemovedEmails(removed)
    }

    private static func normalized(_ credentials: [AntigravityOAuthCredential]) -> [AntigravityOAuthCredential] {
        credentials
            .compactMap { credential in
                let normalizedEmail = self.normalizeEmail(credential.email)
                guard !normalizedEmail.isEmpty else { return nil }
                return AntigravityOAuthCredential(
                    email: normalizedEmail,
                    accessToken: credential.accessToken,
                    refreshToken: credential.refreshToken,
                    accessTokenExpiry: credential.accessTokenExpiry,
                    updatedAt: credential.updatedAt)
            }
            .sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.email < $1.email
            }
    }

    private static func normalizeEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func credentialsFromKeychain() -> [AntigravityOAuthCredential] {
        switch KeychainCacheStore.load(key: self.cacheKey, as: AntigravityOAuthCredentialEnvelope.self) {
        case let .found(entry):
            self.normalized(entry.credentials)
        case .missing, .invalid:
            []
        }
    }

    private static func removedEmails() -> Set<String> {
        guard !self.isRunningTests else {
            return []
        }
        guard let url = self.removedAccountsURL,
              let data = try? Data(contentsOf: url)
        else {
            return []
        }
        guard let envelope = try? JSONDecoder().decode(AntigravityRemovedAccountEnvelope.self, from: data) else {
            return []
        }
        return Set(envelope.emails.map { self.normalizeEmail($0) }.filter { !$0.isEmpty })
    }

    private static func removeRemovedEmail(_ email: String) {
        guard !self.isRunningTests else { return }
        let normalizedEmail = self.normalizeEmail(email)
        guard !normalizedEmail.isEmpty else { return }
        var removed = self.removedEmails()
        let wasRemoved = removed.remove(normalizedEmail) != nil
        guard wasRemoved else { return }
        self.persistRemovedEmails(removed)
    }

    private static func persistRemovedEmails(_ emails: Set<String>) {
        guard !self.isRunningTests else { return }
        guard let url = self.removedAccountsURL else { return }
        let normalized = emails.map { self.normalizeEmail($0) }.filter { !$0.isEmpty }.sorted()
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let envelope = AntigravityRemovedAccountEnvelope(emails: normalized)
            let data = try JSONEncoder().encode(envelope)
            try data.write(to: url, options: [.atomic])
        } catch {
            // Best-effort local filter only.
        }
    }

    private static var removedAccountsURL: URL? {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = root.appendingPathComponent("com.steipete.codexbar", isDirectory: true)
        return directory.appendingPathComponent(self.removedAccountsFileName)
    }

    private static var isRunningTests: Bool {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return true
        }
        return NSClassFromString("XCTestCase") != nil
    }
}
