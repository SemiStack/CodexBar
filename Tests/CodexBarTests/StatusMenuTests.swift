import AppKit
import Testing
@testable import CodexBarCore
@testable import CodexBar

@MainActor
@Suite
struct StatusMenuTests {
    private func disableMenuCardsForTesting() {
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.menuRefreshEnabled = false
    }

    private func makeStatusBarForTesting() -> NSStatusBar {
        let env = ProcessInfo.processInfo.environment
        if env["GITHUB_ACTIONS"] == "true" || env["CI"] == "true" {
            return .system
        }
        return NSStatusBar()
    }

    private func makeSettings() -> SettingsStore {
        let suite = "StatusMenuTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        return SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }

    private func makeCodexSnapshot(email: String, updatedAt: Date) -> UsageSnapshot {
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: email,
            accountOrganization: nil,
            loginMethod: "Team")
        return UsageSnapshot(
            primary: RateWindow(usedPercent: 12, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 34, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            tertiary: nil,
            updatedAt: updatedAt,
            identity: identity)
    }

    private func makeAntigravitySnapshot(email: String, updatedAt: Date) -> UsageSnapshot {
        let identity = ProviderIdentitySnapshot(
            providerID: .antigravity,
            accountEmail: email,
            accountOrganization: nil,
            loginMethod: "Team")
        return UsageSnapshot(
            primary: RateWindow(usedPercent: 20, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 40, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            tertiary: RateWindow(usedPercent: 55, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: updatedAt,
            identity: identity)
    }

    private func makeAntigravityCredential(email: String, updatedAt: Date) -> AntigravityOAuthCredential {
        AntigravityOAuthCredential(
            email: email,
            accessToken: "access-\(email)",
            refreshToken: "refresh-\(email)",
            accessTokenExpiry: updatedAt.addingTimeInterval(3600),
            updatedAt: updatedAt)
    }

    @Test
    func remembersProviderWhenMenuOpens() {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: false)
        }
        if let claudeMeta = registry.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: true)
        }
        if let geminiMeta = registry.metadata[.gemini] {
            settings.setProviderEnabled(provider: .gemini, metadata: geminiMeta, enabled: false)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        let claudeMenu = controller.makeMenu()
        controller.menuWillOpen(claudeMenu)
        #expect(controller.lastMenuProvider == .claude)

        // No providers enabled: fall back to Codex.
        for provider in UsageProvider.allCases {
            if let meta = registry.metadata[provider] {
                settings.setProviderEnabled(provider: provider, metadata: meta, enabled: false)
            }
        }
        let unmappedMenu = controller.makeMenu()
        controller.menuWillOpen(unmappedMenu)
        #expect(controller.lastMenuProvider == .codex)
    }

    @Test
    func providerToggleUpdatesStatusItemVisibility() {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.providerDetectionCompleted = true

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        if let claudeMeta = registry.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: true)
        }
        if let geminiMeta = registry.metadata[.gemini] {
            settings.setProviderEnabled(provider: .gemini, metadata: geminiMeta, enabled: false)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        #expect(controller.statusItems[.claude]?.isVisible == true)

        if let claudeMeta = registry.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: false)
        }
        controller.handleProviderConfigChange(reason: "test")
        #expect(controller.statusItems[.claude]?.isVisible == false)
    }

    @Test
    func hidesOpenAIWebSubmenusWhenNoHistory() {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        if let claudeMeta = registry.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: false)
        }
        if let geminiMeta = registry.metadata[.gemini] {
            settings.setProviderEnabled(provider: .gemini, metadata: geminiMeta, enabled: false)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        store.openAIDashboard = OpenAIDashboardSnapshot(
            signedInEmail: "user@example.com",
            codeReviewRemainingPercent: 100,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            updatedAt: Date())

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        let titles = Set(menu.items.map(\.title))
        #expect(!titles.contains("Credits history"))
        #expect(!titles.contains("Usage breakdown"))
    }

    @Test
    func showsOpenAIWebSubmenusWhenHistoryExists() throws {
        self.disableMenuCardsForTesting()
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "StatusMenuTests-history"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        if let claudeMeta = registry.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: false)
        }
        if let geminiMeta = registry.metadata[.gemini] {
            settings.setProviderEnabled(provider: .gemini, metadata: geminiMeta, enabled: false)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)

        let calendar = Calendar(identifier: .gregorian)
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = 2025
        components.month = 12
        components.day = 18
        let date = try #require(components.date)

        let events = [CreditEvent(date: date, service: "CLI", creditsUsed: 1)]
        let breakdown = OpenAIDashboardSnapshot.makeDailyBreakdown(from: events, maxDays: 30)
        store.openAIDashboard = OpenAIDashboardSnapshot(
            signedInEmail: "user@example.com",
            codeReviewRemainingPercent: 100,
            creditEvents: events,
            dailyBreakdown: breakdown,
            usageBreakdown: breakdown,
            creditsPurchaseURL: nil,
            updatedAt: Date())

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        let usageItem = menu.items.first { ($0.representedObject as? String) == "menuCardUsage" }
        let creditsItem = menu.items.first { ($0.representedObject as? String) == "menuCardCredits" }
        #expect(
            usageItem?.submenu?.items
                .contains { ($0.representedObject as? String) == "usageBreakdownChart" } == true)
        #expect(
            creditsItem?.submenu?.items
                .contains { ($0.representedObject as? String) == "creditsHistoryChart" } == true)
    }

    @Test
    func hidesCodexCreditsSectionEvenWhenCreditsExist() {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.costUsageEnabled = true

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        if let claudeMeta = registry.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: false)
        }
        if let geminiMeta = registry.metadata[.gemini] {
            settings.setProviderEnabled(provider: .gemini, metadata: geminiMeta, enabled: false)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        store.credits = CreditsSnapshot(remaining: 100, events: [], updatedAt: Date())
        store.openAIDashboard = OpenAIDashboardSnapshot(
            signedInEmail: "user@example.com",
            codeReviewRemainingPercent: 100,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            updatedAt: Date())
        store._setTokenSnapshotForTesting(CostUsageTokenSnapshot(
            sessionTokens: 123,
            sessionCostUSD: 0.12,
            last30DaysTokens: 123,
            last30DaysCostUSD: 1.23,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2025-12-23",
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: 123,
                    costUSD: 1.23,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ],
            updatedAt: Date()), provider: .codex)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        let ids = menu.items.compactMap { $0.representedObject as? String }
        let creditsIndex = ids.firstIndex(of: "menuCardCredits")
        let costIndex = ids.firstIndex(of: "menuCardCost")
        #expect(creditsIndex == nil)
        #expect(costIndex != nil)
    }

    @Test
    func hidesTopCodexAccountSwitcherAndAddsSwitchActionToInactiveCard() {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        if let claudeMeta = registry.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: false)
        }
        if let geminiMeta = registry.metadata[.gemini] {
            settings.setProviderEnabled(provider: .gemini, metadata: geminiMeta, enabled: false)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let now = Date()
        let activeEmail = "active@example.com"
        let inactiveEmail = "inactive@example.com"
        let activeSnapshot = self.makeCodexSnapshot(email: activeEmail, updatedAt: now)
        let inactiveSnapshot = self.makeCodexSnapshot(email: inactiveEmail, updatedAt: now.addingTimeInterval(-300))
        store._setSnapshotForTesting(activeSnapshot, provider: .codex)
        store.codexActiveAccountEmail = activeEmail
        store.codexCachedAccounts = [
            CodexCachedAccountRecord(
                email: activeEmail,
                snapshot: activeSnapshot,
                credits: nil,
                dashboard: nil,
                sourceLabel: nil,
                lastError: nil,
                updatedAt: now),
            CodexCachedAccountRecord(
                email: inactiveEmail,
                snapshot: inactiveSnapshot,
                credits: nil,
                dashboard: nil,
                sourceLabel: nil,
                lastError: nil,
                updatedAt: now.addingTimeInterval(-300)),
        ]

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)

        #expect(menu.items.contains { $0.view is CodexAccountSwitcherView } == false)
        let switchItem = menu.items.first {
            ($0.representedObject as? SwitchAccountActionPayload)?.targetEmail == inactiveEmail
        }
        #expect(switchItem != nil)
        #expect(switchItem?.action == #selector(StatusItemController.runSwitchAccount(_:)))
        #expect(switchItem?.isEnabled == true)
    }

    @Test
    func keepsAddAccountActionEnabledWhileCodexLoginIsInProgress() {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        if let claudeMeta = registry.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: false)
        }
        if let geminiMeta = registry.metadata[.gemini] {
            settings.setProviderEnabled(provider: .gemini, metadata: geminiMeta, enabled: false)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        store._setSnapshotForTesting(
            self.makeCodexSnapshot(email: "active@example.com", updatedAt: Date()),
            provider: .codex)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        controller.activeLoginProvider = .codex
        controller.loginTargetEmail = "inactive@example.com"
        controller.loginPhase = .waitingBrowser
        controller.loginTask = Task { @MainActor in }
        defer {
            controller.loginTask?.cancel()
            controller.loginTask = nil
            controller.activeLoginProvider = nil
            controller.loginTargetEmail = nil
            controller.loginPhase = .idle
        }

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        let addTitle = AppLocalization.string("Add Account...", language: settings.appLanguage)
        let addAccountItem = menu.items.first { $0.title == addTitle }
        #expect(addAccountItem != nil)
        #expect(addAccountItem?.action == #selector(StatusItemController.runSwitchAccount(_:)))
        #expect(addAccountItem?.isEnabled == true)
    }

    @Test
    func addsSwitchActionToInactiveAntigravityCard() {
        self.disableMenuCardsForTesting()
        let credentialCacheKey = KeychainCacheStore.Key(category: "oauth", identifier: "antigravity.accounts")
        KeychainCacheStore.setTestStoreForTesting(true)
        defer {
            KeychainCacheStore.clear(key: credentialCacheKey)
            KeychainCacheStore.setTestStoreForTesting(false)
        }
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .antigravity

        let registry = ProviderRegistry.shared
        if let antigravityMeta = registry.metadata[.antigravity] {
            settings.setProviderEnabled(provider: .antigravity, metadata: antigravityMeta, enabled: true)
        }
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: false)
        }
        if let claudeMeta = registry.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: false)
        }
        if let geminiMeta = registry.metadata[.gemini] {
            settings.setProviderEnabled(provider: .gemini, metadata: geminiMeta, enabled: false)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let now = Date()
        let activeEmail = "ag-active@example.com"
        let inactiveEmail = "ag-inactive@example.com"
        AntigravityOAuthCredentialStore.upsert(self.makeAntigravityCredential(email: activeEmail, updatedAt: now))
        AntigravityOAuthCredentialStore.upsert(self.makeAntigravityCredential(email: inactiveEmail, updatedAt: now))
        let activeSnapshot = self.makeAntigravitySnapshot(email: activeEmail, updatedAt: now)
        let inactiveSnapshot = self.makeAntigravitySnapshot(
            email: inactiveEmail,
            updatedAt: now.addingTimeInterval(-300))
        store._setSnapshotForTesting(activeSnapshot, provider: .antigravity)
        store.antigravityActiveAccountEmail = activeEmail
        store.antigravityCachedAccounts = [
            AntigravityCachedAccountRecord(
                email: activeEmail,
                snapshot: activeSnapshot,
                sourceLabel: nil,
                lastError: nil,
                updatedAt: now),
            AntigravityCachedAccountRecord(
                email: inactiveEmail,
                snapshot: inactiveSnapshot,
                sourceLabel: nil,
                lastError: nil,
                updatedAt: now.addingTimeInterval(-300)),
        ]

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)

        #expect(menu.items.contains { $0.view is CodexAccountSwitcherView } == false)
        let switchItem = menu.items.first {
            guard let payload = $0.representedObject as? SwitchAccountActionPayload else { return false }
            return payload.provider == .antigravity && payload.targetEmail == inactiveEmail
        }
        #expect(switchItem != nil)
        #expect(switchItem?.action == #selector(StatusItemController.runSwitchAccount(_:)))
        #expect(switchItem?.isEnabled == true)
    }

    @Test
    func showsExtraUsageForClaudeWhenUsingMenuCardSections() {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .claude
        settings.costUsageEnabled = true
        settings.claudeWebExtrasEnabled = true

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: false)
        }
        if let claudeMeta = registry.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: true)
        }
        if let geminiMeta = registry.metadata[.gemini] {
            settings.setProviderEnabled(provider: .gemini, metadata: geminiMeta, enabled: false)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let identity = ProviderIdentitySnapshot(
            providerID: .claude,
            accountEmail: "user@example.com",
            accountOrganization: nil,
            loginMethod: "web")
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: "Resets soon"),
            secondary: nil,
            tertiary: nil,
            providerCost: ProviderCostSnapshot(
                used: 0,
                limit: 2000,
                currencyCode: "EUR",
                period: "Monthly",
                resetsAt: nil,
                updatedAt: Date()),
            updatedAt: Date(),
            identity: identity)
        store._setSnapshotForTesting(snapshot, provider: .claude)
        store._setTokenSnapshotForTesting(CostUsageTokenSnapshot(
            sessionTokens: 123,
            sessionCostUSD: 0.12,
            last30DaysTokens: 123,
            last30DaysCostUSD: 1.23,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2025-12-23",
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: 123,
                    costUSD: 1.23,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ],
            updatedAt: Date()), provider: .claude)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        let ids = menu.items.compactMap { $0.representedObject as? String }
        #expect(ids.contains("menuCardExtraUsage"))
    }

    @Test
    func showsVertexCostWhenUsageErrorPresent() {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .vertexai
        settings.costUsageEnabled = true

        let registry = ProviderRegistry.shared
        if let vertexMeta = registry.metadata[.vertexai] {
            settings.setProviderEnabled(provider: .vertexai, metadata: vertexMeta, enabled: true)
        }
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: false)
        }
        if let claudeMeta = registry.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: false)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        store._setErrorForTesting("No Vertex AI usage data found for the current project.", provider: .vertexai)
        store._setTokenSnapshotForTesting(CostUsageTokenSnapshot(
            sessionTokens: 10,
            sessionCostUSD: 0.01,
            last30DaysTokens: 100,
            last30DaysCostUSD: 1.0,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2025-12-23",
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: 100,
                    costUSD: 1.0,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ],
            updatedAt: Date()), provider: .vertexai)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        let ids = menu.items.compactMap { $0.representedObject as? String }
        #expect(ids.contains("menuCardCost"))
    }
}
