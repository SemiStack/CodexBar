import Foundation
import Testing
@testable import CodexBarCore
@testable import CodexBar

@MainActor
@Suite
struct AntigravityAccountDisplayTests {
    @Test
    func keepsPreviousAntigravityAccountAsCachedAfterSwitch() throws {
        let credentialCacheKey = KeychainCacheStore.Key(category: "oauth", identifier: "antigravity.accounts")
        KeychainCacheStore.setTestStoreForTesting(true)
        defer {
            KeychainCacheStore.clear(key: credentialCacheKey)
            KeychainCacheStore.setTestStoreForTesting(false)
        }

        let settings = Self.makeSettingsStore(suite: "AntigravityAccountDisplayTests-switch")
        settings.refreshFrequency = .manual
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)

        AntigravityOAuthCredentialStore.upsert(Self.makeCredential(email: "first@example.com", updatedAt: Date()))
        AntigravityOAuthCredentialStore.upsert(Self.makeCredential(email: "second@example.com", updatedAt: Date()))

        let firstSnapshot = Self.makeSnapshot(
            email: "first@example.com",
            updatedAt: Date().addingTimeInterval(-1800))
        store.snapshots[.antigravity] = firstSnapshot
        store.lastSourceLabels[.antigravity] = "local"
        store.refreshAntigravityAccountCacheFromLiveData()

        let secondSnapshot = Self.makeSnapshot(
            email: "second@example.com",
            updatedAt: Date())
        store.snapshots[.antigravity] = secondSnapshot
        store.lastSourceLabels[.antigravity] = "local"
        store.refreshAntigravityAccountCacheFromLiveData()

        let displays = store.antigravityAccountDisplays()
        #expect(displays.contains(where: { $0.email == "first@example.com" }))
        #expect(displays.contains(where: { $0.email == "second@example.com" }))

        let active = try #require(displays.first(where: { $0.email == "second@example.com" }))
        #expect(active.isActive == true)
        #expect(active.isUsingCachedData == false)

        let cached = try #require(displays.first(where: { $0.email == "first@example.com" }))
        #expect(cached.isActive == false)
        #expect(cached.isUsingCachedData == true)
    }

    @Test
    func antigravityActionMenuUsesAddAccountLabelEvenWhenLoggedIn() {
        let settings = Self.makeSettingsStore(suite: "AntigravityAccountDisplayTests-menu")
        settings.refreshFrequency = .manual
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        store.snapshots[.antigravity] = Self.makeSnapshot(
            email: "logged@example.com",
            updatedAt: Date())

        let descriptor = MenuDescriptor.build(
            provider: .antigravity,
            store: store,
            settings: settings,
            account: AccountInfo(email: "logged@example.com", plan: "Team"),
            updateReady: false)
        let expectedLabel = AppLocalization.string("Add Account...", language: settings.appLanguage)
        let actions = descriptor.sections.flatMap(\.entries)
        let matched = actions.first { entry in
            if case let .action(title, .switchAccount(provider, targetEmail)) = entry {
                return title == expectedLabel && provider == .antigravity && targetEmail == nil
            }
            return false
        }

        #expect(matched != nil)
    }

    @Test
    func addingAccountKeepsCurrentActiveAccount() throws {
        let credentialCacheKey = KeychainCacheStore.Key(category: "oauth", identifier: "antigravity.accounts")
        KeychainCacheStore.setTestStoreForTesting(true)
        defer {
            KeychainCacheStore.clear(key: credentialCacheKey)
            KeychainCacheStore.setTestStoreForTesting(false)
        }

        let settings = Self.makeSettingsStore(suite: "AntigravityAccountDisplayTests-add-keep-active")
        settings.refreshFrequency = .manual
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)

        AntigravityOAuthCredentialStore.upsert(Self.makeCredential(email: "active@example.com", updatedAt: Date()))
        AntigravityOAuthCredentialStore.upsert(Self.makeCredential(email: "new@example.com", updatedAt: Date()))

        let activeSnapshot = Self.makeSnapshot(
            email: "active@example.com",
            updatedAt: Date())
        store.snapshots[.antigravity] = activeSnapshot
        store.refreshAntigravityAccountCacheFromLiveData()

        _ = store.cacheAntigravityAccount(
            email: "new@example.com",
            snapshot: nil,
            markActive: false)

        let displays = store.antigravityAccountDisplays()
        let active = try #require(displays.first(where: { $0.email == "active@example.com" }))
        #expect(active.isActive == true)

        let newAccount = try #require(displays.first(where: { $0.email == "new@example.com" }))
        #expect(newAccount.isActive == false)
        #expect(newAccount.snapshot == nil)
    }

    @Test
    func displaySnapshotIdentityUsesRecordEmail() throws {
        let credentialCacheKey = KeychainCacheStore.Key(category: "oauth", identifier: "antigravity.accounts")
        KeychainCacheStore.setTestStoreForTesting(true)
        defer {
            KeychainCacheStore.clear(key: credentialCacheKey)
            KeychainCacheStore.setTestStoreForTesting(false)
        }

        let settings = Self.makeSettingsStore(suite: "AntigravityAccountDisplayTests-identity-fix")
        settings.refreshFrequency = .manual
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)

        let activeEmail = "active@example.com"
        let cachedEmail = "cached@example.com"
        let now = Date()
        AntigravityOAuthCredentialStore.upsert(Self.makeCredential(email: activeEmail, updatedAt: now))
        AntigravityOAuthCredentialStore.upsert(Self.makeCredential(email: cachedEmail, updatedAt: now))
        let activeSnapshot = Self.makeSnapshot(email: activeEmail, updatedAt: now)
        store.snapshots[.antigravity] = activeSnapshot
        store.antigravityActiveAccountEmail = activeEmail
        store.antigravityCachedAccounts = [
            AntigravityCachedAccountRecord(
                email: activeEmail,
                snapshot: activeSnapshot,
                sourceLabel: "local",
                lastError: nil,
                updatedAt: now),
            AntigravityCachedAccountRecord(
                email: cachedEmail,
                snapshot: activeSnapshot,
                sourceLabel: "local",
                lastError: nil,
                updatedAt: now.addingTimeInterval(-60)),
        ]

        let displays = store.antigravityAccountDisplays()
        let cached = try #require(displays.first(where: { $0.email == cachedEmail }))
        #expect(cached.snapshot?.accountEmail(for: .antigravity) == cachedEmail)
    }

    private static func makeSettingsStore(suite: String) -> SettingsStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        return SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }

    private static func makeSnapshot(email: String, updatedAt: Date) -> UsageSnapshot {
        let identity = ProviderIdentitySnapshot(
            providerID: .antigravity,
            accountEmail: email,
            accountOrganization: nil,
            loginMethod: "Team")
        return UsageSnapshot(
            primary: RateWindow(
                usedPercent: 33,
                windowMinutes: 300,
                resetsAt: updatedAt.addingTimeInterval(7200),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 50,
                windowMinutes: 10080,
                resetsAt: updatedAt.addingTimeInterval(12 * 3600),
                resetDescription: nil),
            tertiary: RateWindow(
                usedPercent: 12,
                windowMinutes: nil,
                resetsAt: updatedAt.addingTimeInterval(3600),
                resetDescription: nil),
            providerCost: nil,
            updatedAt: updatedAt,
            identity: identity)
    }

    private static func makeCredential(email: String, updatedAt: Date) -> AntigravityOAuthCredential {
        AntigravityOAuthCredential(
            email: email,
            accessToken: "access-\(email)",
            refreshToken: "refresh-\(email)",
            accessTokenExpiry: updatedAt.addingTimeInterval(3600),
            updatedAt: updatedAt)
    }
}
