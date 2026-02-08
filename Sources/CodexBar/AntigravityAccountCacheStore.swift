import CodexBarCore
import Foundation

struct AntigravityCachedAccountRecord: Codable, Identifiable, Sendable {
    let email: String
    var snapshot: UsageSnapshot?
    var sourceLabel: String?
    var lastError: String?
    var updatedAt: Date

    var id: String {
        self.email
    }
}

struct AntigravityAccountCacheState: Codable, Sendable {
    var activeEmail: String?
    var accounts: [AntigravityCachedAccountRecord]
}

enum AntigravityAccountCacheStore {
    static func load() -> AntigravityAccountCacheState? {
        guard let url = self.cacheURL else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AntigravityAccountCacheState.self, from: data)
    }

    static func save(_ state: AntigravityAccountCacheState) {
        guard let url = self.cacheURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: url, options: [.atomic])
        } catch {
            // Best-effort cache only.
        }
    }

    static func clear() {
        guard let url = self.cacheURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static var cacheURL: URL? {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = root.appendingPathComponent("com.steipete.codexbar", isDirectory: true)
        return dir.appendingPathComponent("antigravity-account-cache.json")
    }
}
