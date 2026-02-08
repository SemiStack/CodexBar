import CodexBarCore

@MainActor
extension StatusItemController {
    func runAntigravityLoginFlow() async {
        AntigravityInteractionDebugLog.append(
            "runAntigravityLoginFlow entered",
            metadata: [
                "phase": String(describing: self.loginPhase),
                "targetEmail": self.loginTargetEmail ?? "",
            ])
        self.loginPhase = .requesting
        let targetEmail = self.loginTargetEmail?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        do {
            if let targetEmail, !targetEmail.isEmpty {
                try await AntigravityAccountManager.switchAccount(email: targetEmail, using: self.store)
                AntigravityInteractionDebugLog.append(
                    "runAntigravityLoginFlow switch succeeded",
                    metadata: ["targetEmail": targetEmail])
                self.loginLogger.info(
                    "Antigravity account switch completed",
                    metadata: ["targetEmail": targetEmail])
            } else {
                self.loginPhase = .waitingBrowser
                let added = try await AntigravityAccountManager.addCurrentAccount(using: self.store)
                AntigravityInteractionDebugLog.append(
                    "runAntigravityLoginFlow add succeeded",
                    metadata: ["email": added])
                self.loginLogger.info(
                    "Antigravity account added",
                    metadata: ["email": added])
                self.postLoginNotification(for: .antigravity)
            }
        } catch {
            let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            let safeMessage = message.isEmpty ? "Unknown Antigravity login error." : message
            AntigravityInteractionDebugLog.append(
                "runAntigravityLoginFlow failed",
                metadata: [
                    "targetEmail": targetEmail ?? "",
                    "error": safeMessage,
                ])
            if let targetEmail, !targetEmail.isEmpty {
                self.presentLoginAlert(
                    title: "Antigravity switch failed",
                    message: safeMessage)
                self.loginLogger.error(
                    "Antigravity account switch failed",
                    metadata: [
                        "targetEmail": targetEmail,
                        "error": safeMessage,
                    ])
            } else {
                self.presentLoginAlert(
                    title: "Antigravity add account failed",
                    message: safeMessage)
                self.loginLogger.error(
                    "Antigravity add account failed",
                    metadata: ["error": safeMessage])
            }
        }

        self.loginPhase = .idle
        AntigravityInteractionDebugLog.append("runAntigravityLoginFlow exited")
    }
}
