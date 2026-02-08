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
}
