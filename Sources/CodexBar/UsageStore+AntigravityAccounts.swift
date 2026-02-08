import CodexBarCore
import Foundation

struct AntigravityAccountDisplay: Identifiable, Sendable {
    let email: String
    let snapshot: UsageSnapshot?
    let sourceLabel: String?
    let updatedAt: Date?
    let isActive: Bool
    let isUsingCachedData: Bool
    let cacheNotice: String?

    var id: String {
        self.email
    }
}

extension UsageStore {
    private static let antigravityCachedAccountLimit: Int = 12

    func antigravityAccountDisplays() -> [AntigravityAccountDisplay] {
        self.pruneStaleAntigravityCachedAccounts()
        let activeEmail = self.currentAntigravityActiveEmail()
        var records = self.antigravityCachedAccounts
        if let activeEmail, !records.contains(where: { $0.email == activeEmail }) {
            records.append(AntigravityCachedAccountRecord(
                email: activeEmail,
                snapshot: nil,
                sourceLabel: nil,
                lastError: nil,
                updatedAt: Date()))
        }
        let sortedRecords = Self.sortAntigravityRecords(records, activeEmail: activeEmail)

        return sortedRecords.map { record in
            let isActive = record.email == activeEmail
            let liveSnapshot = isActive ? self.snapshots[.antigravity] : nil
            let effectiveSnapshot = self.normalizedAntigravitySnapshot(
                liveSnapshot ?? record.snapshot,
                forEmail: record.email)
            let isUsingCachedData = record.snapshot != nil && liveSnapshot == nil

            let notice: String? = {
                if isActive, isUsingCachedData {
                    let updated = UsageFormatter.updatedString(from: record.updatedAt)
                    return AppLocalization.format(
                        "Live refresh unavailable. Showing cached data (%@).",
                        language: AppLocalization.currentLanguage(),
                        updated)
                }
                if !isActive, record.snapshot != nil {
                    let updated = UsageFormatter.updatedString(from: record.updatedAt)
                    return AppLocalization.format(
                        "Cached account (%@).",
                        language: AppLocalization.currentLanguage(),
                        updated)
                }
                if !isActive {
                    return "Cached account. No usage snapshot yet.".appLocalized
                }
                return nil
            }()

            return AntigravityAccountDisplay(
                email: record.email,
                snapshot: effectiveSnapshot,
                sourceLabel: isActive ? (self.lastSourceLabels[.antigravity] ?? record.sourceLabel) : record
                    .sourceLabel,
                updatedAt: effectiveSnapshot?.updatedAt ?? record.updatedAt,
                isActive: isActive,
                isUsingCachedData: isUsingCachedData,
                cacheNotice: notice)
        }
    }

    func refreshAntigravityAccountCacheFromLiveData() {
        let activeEmail = self.currentAntigravityActiveEmail()
        if activeEmail != self.antigravityActiveAccountEmail {
            self.antigravityActiveAccountEmail = activeEmail
        }

        guard let activeEmail else {
            self.persistAntigravityAccountCache()
            return
        }

        var record = self.antigravityCachedAccounts
            .first(where: { $0.email == activeEmail }) ?? AntigravityCachedAccountRecord(
                email: activeEmail,
                snapshot: nil,
                sourceLabel: nil,
                lastError: nil,
                updatedAt: Date())

        if let snapshot = self.snapshots[.antigravity] {
            let scoped = snapshot.scoped(to: .antigravity)
            record.snapshot = scoped
            record.updatedAt = max(record.updatedAt, scoped.updatedAt)
        }
        if let source = self.lastSourceLabels[.antigravity], !source.isEmpty {
            record.sourceLabel = source
        }
        let lastError = self.errors[.antigravity]?.trimmingCharacters(in: .whitespacesAndNewlines)
        record.lastError = (lastError?.isEmpty ?? true) ? nil : lastError

        self.upsertAntigravityCachedAccountRecord(record)
        self.pruneStaleAntigravityCachedAccounts()
    }

    func cacheAntigravityAccount(
        email: String,
        snapshot: UsageSnapshot?,
        markActive: Bool = true) -> String
    {
        let normalized = self.normalizeAntigravityEmail(email) ?? email
        let scoped = snapshot?.scoped(to: .antigravity)
        var record = self.antigravityCachedAccounts
            .first(where: { $0.email == normalized }) ?? AntigravityCachedAccountRecord(
                email: normalized,
                snapshot: nil,
                sourceLabel: nil,
                lastError: nil,
                updatedAt: Date())
        if let scoped {
            record.snapshot = scoped
            record.updatedAt = max(record.updatedAt, scoped.updatedAt)
        } else {
            record.updatedAt = max(record.updatedAt, Date())
        }
        if let source = self.lastSourceLabels[.antigravity], !source.isEmpty {
            record.sourceLabel = source
        }
        if markActive {
            self.antigravityActiveAccountEmail = normalized
        }
        self.upsertAntigravityCachedAccountRecord(record)
        return normalized
    }

    func markAntigravityActiveAccount(email: String?) {
        self.antigravityActiveAccountEmail = self.normalizeAntigravityEmail(email)
        self.antigravityCachedAccounts = Self.sortAntigravityRecords(
            self.antigravityCachedAccounts,
            activeEmail: self.antigravityActiveAccountEmail)
        self.persistAntigravityAccountCache()
    }

    func removeAntigravityCachedAccount(email: String) {
        guard let normalized = self.normalizeAntigravityEmail(email) else { return }
        self.antigravityCachedAccounts.removeAll { $0.email == normalized }
        if self.antigravityActiveAccountEmail == normalized {
            self.antigravityActiveAccountEmail = nil
        }
        self.antigravityCachedAccounts = Self.sortAntigravityRecords(
            self.antigravityCachedAccounts,
            activeEmail: self.antigravityActiveAccountEmail)
        self.persistAntigravityAccountCache()
    }

    func loadAntigravityAccountCache() {
        guard !SettingsStore.isRunningTests else {
            self.antigravityActiveAccountEmail = nil
            self.antigravityCachedAccounts = []
            return
        }
        guard let state = AntigravityAccountCacheStore.load() else { return }
        let normalizedActive = self.normalizeAntigravityEmail(state.activeEmail)
        let normalizedRecords: [AntigravityCachedAccountRecord] = state.accounts.compactMap { record in
            guard let email = self.normalizeAntigravityEmail(record.email) else { return nil }
            return AntigravityCachedAccountRecord(
                email: email,
                snapshot: record.snapshot?.scoped(to: .antigravity),
                sourceLabel: record.sourceLabel,
                lastError: record.lastError,
                updatedAt: record.updatedAt)
        }
        self.antigravityActiveAccountEmail = normalizedActive
        self.antigravityCachedAccounts = Self.trimAntigravityRecords(
            Self.sortAntigravityRecords(normalizedRecords, activeEmail: normalizedActive),
            activeEmail: normalizedActive)
        self.pruneStaleAntigravityCachedAccounts()
    }

    private func pruneStaleAntigravityCachedAccounts() {
        let credentialEmails = Set(AntigravityOAuthCredentialStore.allCredentials().map(\.email))
        let activeEmail = self.antigravityActiveAccountEmail
        var prunedEmails: [String] = []
        self.antigravityCachedAccounts.removeAll { record in
            if record.email == activeEmail { return false }
            if credentialEmails.contains(record.email) { return false }
            prunedEmails.append(record.email)
            return true
        }
        guard !prunedEmails.isEmpty else { return }
        AntigravityInteractionDebugLog.append(
            "pruneStaleAntigravityCachedAccounts removed entries",
            metadata: [
                "activeEmail": activeEmail ?? "",
                "removedEmails": prunedEmails.sorted().joined(separator: ","),
                "credentialEmails": credentialEmails.sorted().joined(separator: ","),
            ])
        self.antigravityCachedAccounts = Self.trimAntigravityRecords(
            Self.sortAntigravityRecords(self.antigravityCachedAccounts, activeEmail: activeEmail),
            activeEmail: activeEmail)
        self.persistAntigravityAccountCache()
    }

    private func persistAntigravityAccountCache() {
        guard !SettingsStore.isRunningTests else { return }
        AntigravityAccountCacheStore.save(AntigravityAccountCacheState(
            activeEmail: self.antigravityActiveAccountEmail,
            accounts: self.antigravityCachedAccounts))
    }

    private func upsertAntigravityCachedAccountRecord(_ record: AntigravityCachedAccountRecord) {
        var records = self.antigravityCachedAccounts.filter { $0.email != record.email }
        records.append(record)
        records = Self.sortAntigravityRecords(records, activeEmail: self.antigravityActiveAccountEmail)
        records = Self.trimAntigravityRecords(records, activeEmail: self.antigravityActiveAccountEmail)
        self.antigravityCachedAccounts = records
        self.persistAntigravityAccountCache()
    }

    func currentAntigravityActiveEmail() -> String? {
        if let normalized = self
            .normalizeAntigravityEmail(self.snapshots[.antigravity]?.accountEmail(for: .antigravity))
        {
            return normalized
        }
        return self.antigravityActiveAccountEmail
    }

    private func normalizeAntigravityEmail(_ email: String?) -> String? {
        guard let trimmed = email?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed.lowercased()
    }

    private func normalizedAntigravitySnapshot(_ snapshot: UsageSnapshot?, forEmail email: String) -> UsageSnapshot? {
        guard let snapshot else { return nil }
        let scoped = snapshot.scoped(to: .antigravity)
        let identity = scoped.identity(for: .antigravity)
        let normalizedEmail = self.normalizeAntigravityEmail(email) ?? email
        if identity?.accountEmail == normalizedEmail {
            return scoped
        }

        let patchedIdentity = ProviderIdentitySnapshot(
            providerID: .antigravity,
            accountEmail: normalizedEmail,
            accountOrganization: identity?.accountOrganization,
            loginMethod: identity?.loginMethod)
        return UsageSnapshot(
            primary: scoped.primary,
            secondary: scoped.secondary,
            tertiary: scoped.tertiary,
            providerCost: scoped.providerCost,
            zaiUsage: scoped.zaiUsage,
            minimaxUsage: scoped.minimaxUsage,
            cursorRequests: scoped.cursorRequests,
            updatedAt: scoped.updatedAt,
            identity: patchedIdentity)
    }

    private static func sortAntigravityRecords(
        _ records: [AntigravityCachedAccountRecord],
        activeEmail: String?) -> [AntigravityCachedAccountRecord]
    {
        records.sorted { lhs, rhs in
            let lhsIsActive = lhs.email == activeEmail
            let rhsIsActive = rhs.email == activeEmail
            if lhsIsActive != rhsIsActive { return lhsIsActive }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.email < rhs.email
        }
    }

    private static func trimAntigravityRecords(
        _ records: [AntigravityCachedAccountRecord],
        activeEmail: String?) -> [AntigravityCachedAccountRecord]
    {
        guard records.count > self.antigravityCachedAccountLimit else { return records }
        var trimmed: [AntigravityCachedAccountRecord] = []
        if let activeEmail,
           let active = records.first(where: { $0.email == activeEmail })
        {
            trimmed.append(active)
        }
        for record in records where record.email != activeEmail {
            if trimmed.count >= Self.antigravityCachedAccountLimit { break }
            trimmed.append(record)
        }
        return trimmed
    }
}
