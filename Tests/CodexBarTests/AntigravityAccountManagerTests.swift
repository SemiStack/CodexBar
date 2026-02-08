import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite
struct AntigravityAccountManagerTests {
    @Test
    func fallbackProjectsPrioritizePreferredProject() {
        let candidates = AntigravityAccountManager.fallbackProjectIDs(
            preferredProjectID: "preferred-project",
            generatedProjectID: "generated-project")

        #expect(candidates == ["preferred-project", "generated-project", "bamboo-precept-lgxtn"])
    }

    @Test
    func fallbackProjectsStartFromGeneratedWhenPreferredMissing() {
        let candidates = AntigravityAccountManager.fallbackProjectIDs(
            preferredProjectID: nil,
            generatedProjectID: "generated-project")

        #expect(candidates == ["generated-project", "bamboo-precept-lgxtn"])
    }

    @Test
    func fallbackProjectsTrimAndDedupeInputs() {
        let candidates = AntigravityAccountManager.fallbackProjectIDs(
            preferredProjectID: "  bamboo-precept-lgxtn ",
            generatedProjectID: "bamboo-precept-lgxtn")

        #expect(candidates == ["bamboo-precept-lgxtn"])
    }

    @Test
    func refreshableCredentialsExcludesActiveAccount() {
        let credentials = [
            Self.credential(email: "active@example.com"),
            Self.credential(email: "other@example.com"),
        ]

        let refreshable = AntigravityAccountManager.refreshableCredentials(
            from: credentials,
            activeEmail: "active@example.com")

        #expect(refreshable.map(\.email) == ["other@example.com"])
    }

    @Test
    func refreshableCredentialsMatchesActiveEmailCaseInsensitively() {
        let credentials = [
            Self.credential(email: "Active@Example.com"),
            Self.credential(email: "other@example.com"),
        ]

        let refreshable = AntigravityAccountManager.refreshableCredentials(
            from: credentials,
            activeEmail: "active@example.com")

        #expect(refreshable.map(\.email) == ["other@example.com"])
    }

    private static func credential(email: String) -> AntigravityOAuthCredential {
        AntigravityOAuthCredential(
            email: email,
            accessToken: "token-\(email)",
            refreshToken: "refresh-\(email)",
            accessTokenExpiry: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }
}
