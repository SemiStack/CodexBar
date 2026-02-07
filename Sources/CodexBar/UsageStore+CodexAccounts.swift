import CodexBarCore
import Foundation

struct CodexAccountDisplay: Identifiable, Sendable {
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
    private static let codexCachedAccountLimit: Int = 12

    func codexAccountDisplays() -> [CodexAccountDisplay] {
        let activeEmail = self.currentCodexActiveEmail()
        var records: [CodexCachedAccountRecord] = self.codexCachedAccounts
        if let activeEmail, !records.contains(where: { $0.email == activeEmail }) {
            records.append(CodexCachedAccountRecord(
                email: activeEmail,
                snapshot: nil,
                credits: nil,
                dashboard: nil,
                sourceLabel: nil,
                lastError: nil,
                updatedAt: Date()))
        }
        let sortedRecords = Self.sortCodexRecords(records, activeEmail: activeEmail)

        return sortedRecords.map { record in
            let isActive = record.email == activeEmail
            let liveSnapshot = isActive ? self.snapshots[.codex] : nil
            let effectiveSnapshot = liveSnapshot ?? record.snapshot
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

            return CodexAccountDisplay(
                email: record.email,
                snapshot: effectiveSnapshot,
                sourceLabel: isActive ? (self.lastSourceLabels[.codex] ?? record.sourceLabel) : record.sourceLabel,
                updatedAt: effectiveSnapshot?.updatedAt ?? record.updatedAt,
                isActive: isActive,
                isUsingCachedData: isUsingCachedData,
                cacheNotice: notice)
        }
    }

    func refreshCodexAccountCacheFromLiveData() {
        let activeEmail = self.currentCodexActiveEmail()
        if activeEmail != self.codexActiveAccountEmail {
            self.codexActiveAccountEmail = activeEmail
        }

        guard let activeEmail else {
            self.persistCodexAccountCache()
            return
        }

        var record = self.codexCachedAccounts.first(where: { $0.email == activeEmail }) ?? CodexCachedAccountRecord(
            email: activeEmail,
            snapshot: nil,
            credits: nil,
            dashboard: nil,
            sourceLabel: nil,
            lastError: nil,
            updatedAt: Date())

        if let snapshot = self.snapshots[.codex] {
            let scoped = snapshot.scoped(to: .codex)
            record.snapshot = scoped
            record.updatedAt = max(record.updatedAt, scoped.updatedAt)
        }
        if let credits = self.credits {
            record.credits = credits
            record.updatedAt = max(record.updatedAt, credits.updatedAt)
        }
        if let dashboard = self.openAIDashboard {
            record.dashboard = dashboard
            record.updatedAt = max(record.updatedAt, dashboard.updatedAt)
        }
        if let source = self.lastSourceLabels[.codex], !source.isEmpty {
            record.sourceLabel = source
        }

        let lastError = [self.errors[.codex], self.lastOpenAIDashboardError, self.lastCreditsError]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
        record.lastError = lastError

        self.upsertCodexCachedAccountRecord(record)
    }

    private func upsertCodexCachedAccountRecord(_ record: CodexCachedAccountRecord) {
        var records = self.codexCachedAccounts.filter { $0.email != record.email }
        records.append(record)
        records = Self.sortCodexRecords(records, activeEmail: self.codexActiveAccountEmail)
        records = Self.trimCodexRecords(records, activeEmail: self.codexActiveAccountEmail)
        self.codexCachedAccounts = records
        self.persistCodexAccountCache()
    }

    func loadCodexAccountCache() {
        guard !SettingsStore.isRunningTests else {
            self.codexActiveAccountEmail = nil
            self.codexCachedAccounts = []
            return
        }
        guard let state = CodexAccountCacheStore.load() else { return }
        let normalizedActive = self.normalizeCodexEmail(state.activeEmail)
        let normalizedRecords: [CodexCachedAccountRecord] = state.accounts.compactMap { record in
            guard let email = self.normalizeCodexEmail(record.email) else { return nil }
            return CodexCachedAccountRecord(
                email: email,
                snapshot: record.snapshot?.scoped(to: .codex),
                credits: record.credits,
                dashboard: record.dashboard,
                sourceLabel: record.sourceLabel,
                lastError: record.lastError,
                updatedAt: record.updatedAt)
        }
        self.codexActiveAccountEmail = normalizedActive
        self.codexCachedAccounts = Self.trimCodexRecords(
            Self.sortCodexRecords(normalizedRecords, activeEmail: normalizedActive),
            activeEmail: normalizedActive)
    }

    private func persistCodexAccountCache() {
        guard !SettingsStore.isRunningTests else { return }
        CodexAccountCacheStore.save(CodexAccountCacheState(
            activeEmail: self.codexActiveAccountEmail,
            accounts: self.codexCachedAccounts))
    }

    private func currentCodexActiveEmail() -> String? {
        if let normalized = self.normalizeCodexEmail(self.codexAccountEmailForOpenAIDashboard()) {
            return normalized
        }
        return self.codexActiveAccountEmail
    }

    private func normalizeCodexEmail(_ email: String?) -> String? {
        guard let trimmed = email?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed.lowercased()
    }

    private static func sortCodexRecords(
        _ records: [CodexCachedAccountRecord],
        activeEmail: String?) -> [CodexCachedAccountRecord]
    {
        records.sorted { lhs, rhs in
            let lhsIsActive = lhs.email == activeEmail
            let rhsIsActive = rhs.email == activeEmail
            if lhsIsActive != rhsIsActive { return lhsIsActive }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.email < rhs.email
        }
    }

    private static func trimCodexRecords(
        _ records: [CodexCachedAccountRecord],
        activeEmail: String?) -> [CodexCachedAccountRecord]
    {
        guard records.count > self.codexCachedAccountLimit else { return records }
        var trimmed: [CodexCachedAccountRecord] = []
        if let activeEmail,
           let active = records.first(where: { $0.email == activeEmail })
        {
            trimmed.append(active)
        }
        for record in records where record.email != activeEmail {
            if trimmed.count >= Self.codexCachedAccountLimit { break }
            trimmed.append(record)
        }
        return trimmed
    }
}
