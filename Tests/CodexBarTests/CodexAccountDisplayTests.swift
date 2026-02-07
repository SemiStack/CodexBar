import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite
struct CodexAccountDisplayTests {
    @Test
    func keepsPreviousCodexAccountAsCachedAfterSwitch() throws {
        let settings = Self.makeSettingsStore(suite: "CodexAccountDisplayTests-switch")
        settings.refreshFrequency = .manual
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)

        let firstSnapshot = Self.makeCodexSnapshot(
            email: "first@example.com",
            updatedAt: Date().addingTimeInterval(-1800))
        store.snapshots[.codex] = firstSnapshot
        store.lastSourceLabels[.codex] = "oauth"
        store.refreshCodexAccountCacheFromLiveData()

        let secondSnapshot = Self.makeCodexSnapshot(
            email: "second@example.com",
            updatedAt: Date())
        store.snapshots[.codex] = secondSnapshot
        store.lastSourceLabels[.codex] = "oauth"
        store.refreshCodexAccountCacheFromLiveData()

        let displays = store.codexAccountDisplays()
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
    func codexActionMenuUsesAddAccountLabelEvenWhenLoggedIn() {
        let settings = Self.makeSettingsStore(suite: "CodexAccountDisplayTests-menu")
        settings.refreshFrequency = .manual
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        store.snapshots[.codex] = Self.makeCodexSnapshot(
            email: "logged@example.com",
            updatedAt: Date())

        let descriptor = MenuDescriptor.build(
            provider: .codex,
            store: store,
            settings: settings,
            account: AccountInfo(email: "logged@example.com", plan: "Plus"),
            updateReady: false)
        let expectedLabel = AppLocalization.string("Add Account...", language: settings.appLanguage)
        let actions = descriptor.sections.flatMap(\.entries)
        let matched = actions.first { entry in
            if case let .action(title, .switchAccount(provider, targetEmail)) = entry {
                return title == expectedLabel && provider == .codex && targetEmail == nil
            }
            return false
        }

        #expect(matched != nil)
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

    private static func makeCodexSnapshot(email: String, updatedAt: Date) -> UsageSnapshot {
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: email,
            accountOrganization: nil,
            loginMethod: "Plus")
        return UsageSnapshot(
            primary: RateWindow(
                usedPercent: 55,
                windowMinutes: 300,
                resetsAt: updatedAt.addingTimeInterval(7200),
                resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            updatedAt: updatedAt,
            identity: identity)
    }
}
