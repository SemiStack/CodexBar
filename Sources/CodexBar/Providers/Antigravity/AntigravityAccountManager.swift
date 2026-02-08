import AppKit
import CodexBarCore
import Foundation
import Network
import SQLite3

enum AntigravityAccountManagerError: LocalizedError {
    case accountEmailUnavailable
    case accountNotAdded(String)
    case oauthBrowserOpenFailed
    case oauthCodeMissing
    case oauthStateMismatch
    case oauthTimedOut
    case oauthCancelled
    case oauthTokenExchangeFailed(String)
    case oauthUserInfoFailed(String)
    case oauthRefreshFailed(String)
    case oauthRefreshTokenMissing
    case apiRequestFailed(String)
    case cannotRemoveActiveAccount(String)
    case databaseNotFound
    case databaseOpenFailed(String)
    case databaseWriteFailed(String)
    case callbackListenerFailed(String)

    var errorDescription: String? {
        switch self {
        case .accountEmailUnavailable:
            "Could not determine the Antigravity account email."
        case let .accountNotAdded(email):
            "Account \(email) has not been added yet."
        case .oauthBrowserOpenFailed:
            "Could not open browser for Google sign-in."
        case .oauthCodeMissing:
            "Google OAuth callback did not include an authorization code."
        case .oauthStateMismatch:
            "Google OAuth state mismatch. Please retry."
        case .oauthTimedOut:
            "Google OAuth timed out. Please retry."
        case .oauthCancelled:
            "Google OAuth was cancelled."
        case let .oauthTokenExchangeFailed(details):
            "Google OAuth token exchange failed: \(details)"
        case let .oauthUserInfoFailed(details):
            "Failed to fetch Google account profile: \(details)"
        case let .oauthRefreshFailed(details):
            "Failed to refresh Google token: \(details)"
        case .oauthRefreshTokenMissing:
            "Google did not return a refresh token. Revoke access and retry."
        case let .apiRequestFailed(details):
            "Failed to fetch Antigravity account usage: \(details)"
        case let .cannotRemoveActiveAccount(email):
            "Cannot remove active account \(email). Switch to another account first."
        case .databaseNotFound:
            "Antigravity state database was not found."
        case let .databaseOpenFailed(details):
            "Failed to open Antigravity state database: \(details)"
        case let .databaseWriteFailed(details):
            "Failed to update Antigravity state database: \(details)"
        case let .callbackListenerFailed(details):
            "Failed to start OAuth callback listener: \(details)"
        }
    }
}

private struct AntigravityOAuthConfiguration: Sendable {
    let clientID: String
    let clientSecret: String?
}

private struct AntigravityOAuthTokenResponse: Codable, Sendable {
    let accessToken: String
    let expiresIn: TimeInterval
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
    }
}

private struct AntigravityGoogleUserInfo: Codable, Sendable {
    let email: String
}

private struct AntigravityLoadCodeAssistResponse: Codable, Sendable {
    let cloudaicompanionProject: String?
    let currentTier: AntigravityTierInfo?
    let paidTier: AntigravityTierInfo?
}

private struct AntigravityTierInfo: Codable, Sendable {
    let id: String?
    let name: String?
}

private struct AntigravityFetchModelsResponse: Codable, Sendable {
    let models: [String: AntigravityFetchModelInfo]?
}

private struct AntigravityFetchModelInfo: Codable, Sendable {
    let quotaInfo: AntigravityFetchQuotaInfo?
}

private struct AntigravityFetchQuotaInfo: Codable, Sendable {
    let remainingFraction: Double?
    let resetTime: String?
}

private struct AntigravityFetchedQuota: Sendable {
    let label: String
    let modelID: String
    let remainingFraction: Double?
    let resetTime: Date?
}

private struct AntigravityOAuthCallback: Sendable {
    let code: String
    let state: String?
}

private final class AntigravityOAuthCallbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "codexbar.antigravity.oauth.callback")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AntigravityOAuthCallback, Error>?
    private var pendingResult: Result<AntigravityOAuthCallback, Error>?
    private var completed = false

    private(set) var redirectURI: String = ""

    init() throws {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            self.listener = try NWListener(using: params, on: .any)
        } catch {
            throw AntigravityAccountManagerError.callbackListenerFailed(error.localizedDescription)
        }

        let readySemaphore = DispatchSemaphore(value: 0)
        final class ListenerStartupState: @unchecked Sendable {
            var error: Error?
        }
        let startupState = ListenerStartupState()
        self.listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                readySemaphore.signal()
            case let .failed(error):
                startupState.error = error
                readySemaphore.signal()
            default:
                break
            }
        }
        self.listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }
        self.listener.start(queue: self.queue)

        if readySemaphore.wait(timeout: .now() + 5) == .timedOut {
            self.listener.cancel()
            throw AntigravityAccountManagerError.callbackListenerFailed("listener startup timed out")
        }
        if let startupError = startupState.error {
            self.listener.cancel()
            throw AntigravityAccountManagerError.callbackListenerFailed(startupError.localizedDescription)
        }
        guard let port = self.listener.port?.rawValue else {
            self.listener.cancel()
            throw AntigravityAccountManagerError.callbackListenerFailed("listener port unavailable")
        }
        self.redirectURI = "http://127.0.0.1:\(port)/oauth-callback"
    }

    deinit {
        self.listener.cancel()
    }

    func waitForCallback(timeout: TimeInterval) async throws -> AntigravityOAuthCallback {
        try await withCheckedThrowingContinuation { continuation in
            self.lock.lock()
            if let pendingResult = self.pendingResult {
                self.pendingResult = nil
                self.lock.unlock()
                continuation.resume(with: pendingResult)
                return
            }
            if self.completed {
                self.lock.unlock()
                continuation.resume(throwing: AntigravityAccountManagerError.oauthCancelled)
                return
            }
            self.continuation = continuation
            self.lock.unlock()

            self.queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.resolve(.failure(AntigravityAccountManagerError.oauthTimedOut))
            }
        }
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: self.queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }
            let result = self.parseCallback(data: data)
            let response = self.httpResponse(for: result)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
            self.resolve(result)
        }
    }

    private func parseCallback(data: Data?) -> Result<AntigravityOAuthCallback, Error> {
        guard let data, !data.isEmpty else {
            return .failure(AntigravityAccountManagerError.oauthCodeMissing)
        }
        let request = String(bytes: data, encoding: .utf8) ?? ""
        guard let firstLine = request.components(separatedBy: "\r\n").first else {
            return .failure(AntigravityAccountManagerError.oauthCodeMissing)
        }
        let parts = firstLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            return .failure(AntigravityAccountManagerError.oauthCodeMissing)
        }
        let pathAndQuery = String(parts[1])
        guard let components = URLComponents(string: "http://127.0.0.1\(pathAndQuery)"),
              components.path == "/oauth-callback"
        else {
            return .failure(AntigravityAccountManagerError.oauthCodeMissing)
        }

        var code: String?
        var state: String?
        for item in components.queryItems ?? [] {
            if item.name == "code", let value = item.value, !value.isEmpty {
                code = value
            } else if item.name == "state", let value = item.value, !value.isEmpty {
                state = value
            }
        }
        guard let code else {
            return .failure(AntigravityAccountManagerError.oauthCodeMissing)
        }
        return .success(AntigravityOAuthCallback(code: code, state: state))
    }

    private func httpResponse(for result: Result<AntigravityOAuthCallback, Error>) -> Data {
        let html: String
        let statusLine: String
        switch result {
        case .success:
            statusLine = "HTTP/1.1 200 OK"
            html = """
            <html><body style='font-family:sans-serif;text-align:center;padding:40px;'>
            <h2 style='color:#1c7d2f;'>Authorization complete</h2>
            <p>You can close this tab and return to CodexBar.</p>
            </body></html>
            """
        case .failure:
            statusLine = "HTTP/1.1 400 Bad Request"
            html = """
            <html><body style='font-family:sans-serif;text-align:center;padding:40px;'>
            <h2 style='color:#b42318;'>Authorization failed</h2>
            <p>Return to CodexBar and try again.</p>
            </body></html>
            """
        }
        let response = "\(statusLine)\r\nContent-Type: text/html; charset=utf-8\r\n\r\n\(html)"
        return Data(response.utf8)
    }

    private func resolve(_ result: Result<AntigravityOAuthCallback, Error>) {
        self.lock.lock()
        guard !self.completed else {
            self.lock.unlock()
            return
        }
        self.completed = true
        let continuation = self.continuation
        self.continuation = nil
        if continuation == nil {
            self.pendingResult = result
        }
        self.lock.unlock()

        self.listener.cancel()
        continuation?.resume(with: result)
    }
}

// swiftlint:disable type_body_length
@MainActor
enum AntigravityAccountManager {
    private static let log = CodexBarLog.logger(LogCategories.antigravity)

    private static let defaultClientID = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
    private static let defaultClientSecret = "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"
    private static let environmentClientIDKey = "CODEXBAR_AG_OAUTH_CLIENT_ID"
    private static let environmentClientSecretKey = "CODEXBAR_AG_OAUTH_CLIENT_SECRET"

    private static let authorizationEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    private static let tokenEndpoint = "https://oauth2.googleapis.com/token"
    private static let userInfoEndpoint = "https://www.googleapis.com/oauth2/v2/userinfo"
    private static let cloudCodeBaseURL = "https://daily-cloudcode-pa.sandbox.googleapis.com"
    private static let loadCodeAssistEndpoint = "\(cloudCodeBaseURL)/v1internal:loadCodeAssist"
    private static let fetchModelsEndpoint = "\(cloudCodeBaseURL)/v1internal:fetchAvailableModels"
    private static let defaultCloudCodeProject = "bamboo-precept-lgxtn"

    private static var cloudCodeUserAgent: String {
        self.makeCloudCodeUserAgent()
    }

    private static let fallbackProjectAdjectives = ["useful", "bright", "swift", "calm", "bold"]
    private static let fallbackProjectNouns = ["fuze", "wave", "spark", "flow", "core"]
    private static let oauthScopes = [
        "https://www.googleapis.com/auth/cloud-platform",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile",
        "https://www.googleapis.com/auth/cclog",
        "https://www.googleapis.com/auth/experimentsandconfigs",
    ]

    private static let unifiedOAuthKey = "antigravityUnifiedStateSync.oauthToken"
    private static let legacyOAuthKey = "jetskiStateSync.agentManagerInitState"
    private static let onboardingKey = "antigravityOnboarding"

    static func addCurrentAccount(using store: UsageStore) async throws -> String {
        AntigravityInteractionDebugLog.append("addCurrentAccount started")
        let configuration = self.oauthConfiguration()
        let callbackServer = try AntigravityOAuthCallbackServer()
        let state = UUID().uuidString
        let authURL = try self.authorizationURL(
            redirectURI: callbackServer.redirectURI,
            state: state,
            configuration: configuration)

        async let callback = callbackServer.waitForCallback(timeout: 240)
        guard NSWorkspace.shared.open(authURL) else {
            AntigravityInteractionDebugLog.append("addCurrentAccount failed to open browser")
            throw AntigravityAccountManagerError.oauthBrowserOpenFailed
        }
        AntigravityInteractionDebugLog.append(
            "addCurrentAccount opened browser",
            metadata: ["redirectURI": callbackServer.redirectURI])

        let payload = try await callback
        guard payload.state == state else {
            AntigravityInteractionDebugLog.append(
                "addCurrentAccount state mismatch",
                metadata: [
                    "expected": state,
                    "received": payload.state ?? "",
                ])
            throw AntigravityAccountManagerError.oauthStateMismatch
        }

        let token = try await self.exchangeCode(
            payload.code,
            redirectURI: callbackServer.redirectURI,
            configuration: configuration)
        guard let refreshToken = token.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !refreshToken.isEmpty
        else {
            throw AntigravityAccountManagerError.oauthRefreshTokenMissing
        }

        let userInfo = try await self.fetchUserInfo(accessToken: token.accessToken)
        let normalizedEmail = userInfo.email
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedEmail.isEmpty else {
            throw AntigravityAccountManagerError.accountEmailUnavailable
        }

        let credential = AntigravityOAuthCredential(
            email: normalizedEmail,
            accessToken: token.accessToken,
            refreshToken: refreshToken,
            accessTokenExpiry: Date().addingTimeInterval(token.expiresIn),
            updatedAt: Date())
        AntigravityOAuthCredentialStore.upsert(credential)

        let cachedSnapshot = await self.fetchCachedUsageSnapshotIfPossible(
            email: normalizedEmail,
            accessToken: token.accessToken)
        let normalized = store.cacheAntigravityAccount(
            email: normalizedEmail,
            snapshot: cachedSnapshot,
            markActive: false)
        AntigravityInteractionDebugLog.append(
            "addCurrentAccount completed",
            metadata: [
                "email": normalized,
                "hasSnapshot": cachedSnapshot == nil ? "false" : "true",
            ])
        self.log.info("Antigravity account added via OAuth", metadata: ["email": normalized])
        return normalized
    }

    static func switchAccount(email: String, using store: UsageStore) async throws {
        AntigravityInteractionDebugLog.append(
            "switchAccount started",
            metadata: ["email": email])
        let normalized = email
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else {
            throw AntigravityAccountManagerError.accountEmailUnavailable
        }
        guard var credential = AntigravityOAuthCredentialStore.credential(for: normalized) else {
            throw AntigravityAccountManagerError.accountNotAdded(normalized)
        }

        credential = try await self.refreshCredentialIfNeeded(credential)
        AntigravityOAuthCredentialStore.upsert(credential)

        let databaseURL = try await self.resolveDatabaseURL()
        try self.injectCredential(credential, databaseURL: databaseURL)

        store.markAntigravityActiveAccount(email: normalized)
        AntigravityInteractionDebugLog.append(
            "switchAccount completed",
            metadata: [
                "email": normalized,
                "databaseURL": databaseURL.path,
            ])
        self.log.info("Antigravity account switched", metadata: ["email": normalized])
    }

    static func removeAccount(email: String, using store: UsageStore) throws {
        AntigravityInteractionDebugLog.append(
            "removeAccount started",
            metadata: ["email": email])
        let normalized = email
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else {
            throw AntigravityAccountManagerError.accountEmailUnavailable
        }

        let activeEmail = store.antigravityAccountDisplays()
            .first(where: { $0.isActive })?
            .email ?? store.antigravityActiveAccountEmail
        if activeEmail == normalized {
            throw AntigravityAccountManagerError.cannotRemoveActiveAccount(normalized)
        }

        AntigravityOAuthCredentialStore.remove(email: normalized)
        store.removeAntigravityCachedAccount(email: normalized)
        AntigravityInteractionDebugLog.append(
            "removeAccount completed",
            metadata: ["email": normalized])
        self.log.info("Antigravity account removed", metadata: ["email": normalized])
    }

    private static func oauthConfiguration() -> AntigravityOAuthConfiguration {
        let env = ProcessInfo.processInfo.environment
        let envClientID = env[self.environmentClientIDKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let clientID: String = if let envClientID, !envClientID.isEmpty {
            envClientID
        } else {
            self.defaultClientID
        }
        let envSecret = env[self.environmentClientSecretKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientSecret: String? = {
            if let envSecret, !envSecret.isEmpty {
                return envSecret
            }
            return self.defaultClientSecret
        }()
        return AntigravityOAuthConfiguration(clientID: clientID, clientSecret: clientSecret)
    }

    private static func authorizationURL(
        redirectURI: String,
        state: String,
        configuration: AntigravityOAuthConfiguration) throws -> URL
    {
        guard var components = URLComponents(string: self.authorizationEndpoint) else {
            throw AntigravityAccountManagerError.oauthBrowserOpenFailed
        }
        components.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: self.oauthScopes.joined(separator: " ")),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "select_account consent"),
            URLQueryItem(name: "include_granted_scopes", value: "true"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components.url else {
            throw AntigravityAccountManagerError.oauthBrowserOpenFailed
        }
        return url
    }

    private static func exchangeCode(
        _ code: String,
        redirectURI: String,
        configuration: AntigravityOAuthConfiguration) async throws -> AntigravityOAuthTokenResponse
    {
        var params: [String: String] = [
            "client_id": configuration.clientID,
            "code": code,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
        ]
        if let clientSecret = configuration.clientSecret, !clientSecret.isEmpty {
            params["client_secret"] = clientSecret
        }
        let data = try await self.performFormPOST(urlString: self.tokenEndpoint, parameters: params)
        do {
            return try JSONDecoder().decode(AntigravityOAuthTokenResponse.self, from: data)
        } catch {
            throw AntigravityAccountManagerError.oauthTokenExchangeFailed(error.localizedDescription)
        }
    }

    private static func refreshCredentialIfNeeded(
        _ credential: AntigravityOAuthCredential) async throws -> AntigravityOAuthCredential
    {
        let refreshLeadTime: TimeInterval = 300
        if credential.accessTokenExpiry.timeIntervalSinceNow > refreshLeadTime {
            return credential
        }
        let configuration = self.oauthConfiguration()
        var params: [String: String] = [
            "client_id": configuration.clientID,
            "refresh_token": credential.refreshToken,
            "grant_type": "refresh_token",
        ]
        if let clientSecret = configuration.clientSecret, !clientSecret.isEmpty {
            params["client_secret"] = clientSecret
        }
        let data = try await self.performFormPOST(urlString: self.tokenEndpoint, parameters: params)
        let response: AntigravityOAuthTokenResponse
        do {
            response = try JSONDecoder().decode(AntigravityOAuthTokenResponse.self, from: data)
        } catch {
            throw AntigravityAccountManagerError.oauthRefreshFailed(error.localizedDescription)
        }
        return AntigravityOAuthCredential(
            email: credential.email,
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? credential.refreshToken,
            accessTokenExpiry: Date().addingTimeInterval(response.expiresIn),
            updatedAt: Date())
    }

    private static func fetchUserInfo(accessToken: String) async throws -> AntigravityGoogleUserInfo {
        guard let url = URL(string: self.userInfoEndpoint) else {
            throw AntigravityAccountManagerError.oauthUserInfoFailed("invalid endpoint")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AntigravityAccountManagerError.oauthUserInfoFailed(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AntigravityAccountManagerError.oauthUserInfoFailed("invalid response")
        }
        guard (200...299).contains(http.statusCode) else {
            let details = String(bytes: data, encoding: .utf8) ?? ""
            throw AntigravityAccountManagerError.oauthUserInfoFailed(
                "HTTP \(http.statusCode): \(details)")
        }
        do {
            return try JSONDecoder().decode(AntigravityGoogleUserInfo.self, from: data)
        } catch {
            throw AntigravityAccountManagerError.oauthUserInfoFailed(error.localizedDescription)
        }
    }

    private static func fetchCachedUsageSnapshotIfPossible(
        email: String,
        accessToken: String) async -> UsageSnapshot?
    {
        AntigravityInteractionDebugLog.append(
            "addCurrentAccount fetch cached snapshot started",
            metadata: ["email": email])
        do {
            let resolved = try await self.fetchProjectIDAndPlan(accessToken: accessToken)
            let planName = resolved.1
            let projectID = self.normalizedProjectID(resolved.0) ?? self.defaultCloudCodeProject
            let quotas = try await self.fetchAvailableModels(
                accessToken: accessToken,
                projectID: projectID)
            guard !quotas.isEmpty else {
                AntigravityInteractionDebugLog.append(
                    "addCurrentAccount fetch cached snapshot empty",
                    metadata: [
                        "email": email,
                        "projectID": projectID,
                    ])
                return nil
            }
            let ordered = self.orderedFetchedQuotas(quotas)
            guard let primaryQuota = ordered.first else {
                AntigravityInteractionDebugLog.append(
                    "addCurrentAccount fetch cached snapshot empty ordered",
                    metadata: [
                        "email": email,
                        "projectID": projectID,
                    ])
                return nil
            }
            let primary = self.rateWindow(for: primaryQuota)
            let secondary = ordered.count > 1 ? self.rateWindow(for: ordered[1]) : nil
            let tertiary = ordered.count > 2 ? self.rateWindow(for: ordered[2]) : nil
            let identity = ProviderIdentitySnapshot(
                providerID: .antigravity,
                accountEmail: email,
                accountOrganization: nil,
                loginMethod: planName)
            let snapshot = UsageSnapshot(
                primary: primary,
                secondary: secondary,
                tertiary: tertiary,
                updatedAt: Date(),
                identity: identity)
                .scoped(to: .antigravity)
            AntigravityInteractionDebugLog.append(
                "addCurrentAccount fetch cached snapshot succeeded",
                metadata: [
                    "email": email,
                    "projectID": projectID,
                    "modelCount": String(quotas.count),
                ])
            return snapshot
        } catch {
            AntigravityInteractionDebugLog.append(
                "addCurrentAccount fetch cached snapshot failed",
                metadata: [
                    "email": email,
                    "error": error.localizedDescription,
                ])
            return nil
        }
    }

    private static func makeCloudCodeUserAgent() -> String {
        let osName: String = {
            #if os(macOS)
            return "darwin"
            #elseif os(Linux)
            return "linux"
            #elseif os(Windows)
            return "windows"
            #else
            return "unknown"
            #endif
        }()
        let architecture: String = {
            #if arch(arm64)
            return "arm64"
            #elseif arch(x86_64)
            return "amd64"
            #elseif arch(i386)
            return "386"
            #else
            return "unknown"
            #endif
        }()
        // CloudCode gates fetchAvailableModels by client fingerprint; keep an Antigravity-like UA.
        return "antigravity/0.0.0 \(osName)/\(architecture)"
    }

    static func fallbackProjectIDs(preferredProjectID: String?, generatedProjectID: String) -> [String] {
        let preferred = self.normalizedProjectID(preferredProjectID)
        let generated = self.normalizedProjectID(generatedProjectID)
        let defaultProject = self.normalizedProjectID(self.defaultCloudCodeProject)

        var candidates: [String] = []
        if let preferred {
            candidates.append(preferred)
            if let generated, generated != preferred {
                candidates.append(generated)
            }
            if let defaultProject,
               defaultProject != preferred,
               defaultProject != generated
            {
                candidates.append(defaultProject)
            }
            return candidates
        }

        if let generated {
            candidates.append(generated)
        }
        if let defaultProject, defaultProject != generated {
            candidates.append(defaultProject)
        }
        return candidates
    }

    private static func fetchAvailableModelsWithFallback(
        accessToken: String,
        email: String,
        projectIDs: [String]) async throws -> (projectID: String, quotas: [AntigravityFetchedQuota])
    {
        guard !projectIDs.isEmpty else {
            throw AntigravityAccountManagerError.apiRequestFailed("no project ID candidates available")
        }
        var lastError: Error?
        var lastEmptyProject: String?
        for projectID in projectIDs {
            do {
                let quotas = try await self.fetchAvailableModels(
                    accessToken: accessToken,
                    projectID: projectID)
                if quotas.isEmpty {
                    lastEmptyProject = projectID
                    AntigravityInteractionDebugLog.append(
                        "addCurrentAccount fetch cached snapshot project empty",
                        metadata: [
                            "email": email,
                            "projectID": projectID,
                        ])
                    continue
                }
                return (projectID: projectID, quotas: quotas)
            } catch {
                lastError = error
                AntigravityInteractionDebugLog.append(
                    "addCurrentAccount fetch cached snapshot project failed",
                    metadata: [
                        "email": email,
                        "projectID": projectID,
                        "error": error.localizedDescription,
                    ])
                if self.isFetchAvailableModelsForbidden(error) {
                    continue
                }
            }
        }
        if let lastError {
            throw lastError
        }
        if let lastEmptyProject {
            return (projectID: lastEmptyProject, quotas: [])
        }
        throw AntigravityAccountManagerError.apiRequestFailed("fetchAvailableModels returned no usable quota data")
    }

    private static func isFetchAvailableModelsForbidden(_ error: Error) -> Bool {
        if case let AntigravityAccountManagerError.apiRequestFailed(details) = error {
            return details.contains("fetchAvailableModels HTTP 403")
        }
        let message = error.localizedDescription.lowercased()
        return message.contains("fetchavailablemodels") && message.contains("403")
    }

    private static func normalizedProjectID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func generateFallbackProjectID() -> String {
        let adjectiveIndex = Int.random(in: 0..<self.fallbackProjectAdjectives.count)
        let nounIndex = Int.random(in: 0..<self.fallbackProjectNouns.count)
        let adjective = self.fallbackProjectAdjectives[adjectiveIndex]
        let noun = self.fallbackProjectNouns[nounIndex]
        let suffix = UUID()
            .uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
            .prefix(5)
        return "\(adjective)-\(noun)-\(suffix)"
    }

    private static func fetchProjectIDAndPlan(accessToken: String) async throws -> (String?, String?) {
        guard let url = URL(string: self.loadCodeAssistEndpoint) else {
            throw AntigravityAccountManagerError.apiRequestFailed("invalid loadCodeAssist endpoint")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(self.cloudCodeUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("{\"metadata\":{\"ideType\":\"ANTIGRAVITY\"}}".utf8)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AntigravityAccountManagerError.apiRequestFailed("loadCodeAssist: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw AntigravityAccountManagerError.apiRequestFailed("loadCodeAssist: invalid response")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(bytes: data, encoding: .utf8) ?? ""
            throw AntigravityAccountManagerError.apiRequestFailed(
                "loadCodeAssist HTTP \(http.statusCode): \(body)")
        }
        let payload: AntigravityLoadCodeAssistResponse
        do {
            payload = try JSONDecoder().decode(AntigravityLoadCodeAssistResponse.self, from: data)
        } catch {
            throw AntigravityAccountManagerError.apiRequestFailed(
                "loadCodeAssist decode failed: \(error.localizedDescription)")
        }
        let tier = payload.paidTier?.name ?? payload.currentTier?.name ?? payload.paidTier?.id ?? payload.currentTier?
            .id
        return (payload.cloudaicompanionProject, self.normalizePlanName(tier))
    }

    private static func fetchAvailableModels(
        accessToken: String,
        projectID: String) async throws -> [AntigravityFetchedQuota]
    {
        guard let url = URL(string: self.fetchModelsEndpoint) else {
            throw AntigravityAccountManagerError.apiRequestFailed("invalid fetchAvailableModels endpoint")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(self.cloudCodeUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("{\"project\":\"\(projectID)\"}".utf8)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AntigravityAccountManagerError.apiRequestFailed(
                "fetchAvailableModels: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw AntigravityAccountManagerError.apiRequestFailed("fetchAvailableModels: invalid response")
        }
        if http.statusCode == 403 {
            throw AntigravityAccountManagerError.apiRequestFailed("fetchAvailableModels HTTP 403")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(bytes: data, encoding: .utf8) ?? ""
            throw AntigravityAccountManagerError.apiRequestFailed(
                "fetchAvailableModels HTTP \(http.statusCode): \(body)")
        }
        let payload: AntigravityFetchModelsResponse
        do {
            payload = try JSONDecoder().decode(AntigravityFetchModelsResponse.self, from: data)
        } catch {
            throw AntigravityAccountManagerError.apiRequestFailed(
                "fetchAvailableModels decode failed: \(error.localizedDescription)")
        }
        let models = payload.models ?? [:]
        var buckets: [String: AntigravityFetchedQuota] = [:]
        for (modelID, info) in models {
            guard let quota = info.quotaInfo else { continue }
            guard let label = self.displayLabel(forModelID: modelID) else { continue }
            let candidate = AntigravityFetchedQuota(
                label: label,
                modelID: modelID,
                remainingFraction: quota.remainingFraction,
                resetTime: self.parseResetTime(quota.resetTime))
            if let existing = buckets[label],
               (existing.remainingFraction ?? -1) >= (candidate.remainingFraction ?? -1)
            {
                continue
            }
            buckets[label] = candidate
        }
        let order = ["Claude", "Gemini Pro low", "Gemini Flash"]
        return order.compactMap { buckets[$0] }
    }

    private static func orderedFetchedQuotas(_ quotas: [AntigravityFetchedQuota]) -> [AntigravityFetchedQuota] {
        let order = ["Claude", "Gemini Pro low", "Gemini Flash"]
        var ordered: [AntigravityFetchedQuota] = []
        for label in order {
            if let quota = quotas.first(where: { $0.label == label }) {
                ordered.append(quota)
            }
        }
        if ordered.isEmpty {
            return quotas.sorted { ($0.remainingFraction ?? 0) < ($1.remainingFraction ?? 0) }
        }
        return ordered
    }

    private static func rateWindow(for quota: AntigravityFetchedQuota) -> RateWindow {
        let remainingPercent = max(0, min(100, (quota.remainingFraction ?? 0) * 100))
        return RateWindow(
            usedPercent: 100 - remainingPercent,
            windowMinutes: nil,
            resetsAt: quota.resetTime,
            resetDescription: nil)
    }

    private static func displayLabel(forModelID modelID: String) -> String? {
        let lower = modelID.lowercased()
        if lower.contains("claude"), !lower.contains("thinking") {
            return "Claude"
        }
        if lower.contains("gemini"), lower.contains("pro") {
            return "Gemini Pro low"
        }
        if lower.contains("gemini"), lower.contains("flash") {
            return "Gemini Flash"
        }
        return nil
    }

    private static func parseResetTime(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        if let iso = ISO8601DateFormatter().date(from: raw) {
            return iso
        }
        if let seconds = Double(raw) {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }

    private static func normalizePlanName(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let lower = raw.lowercased()
        if lower.contains("pro") || lower.contains("paid") {
            return "Pro"
        }
        if lower.contains("free") {
            return "Free"
        }
        return raw
    }

    private static func performFormPOST(
        urlString: String,
        parameters: [String: String]) async throws -> Data
    {
        guard let url = URL(string: urlString) else {
            throw AntigravityAccountManagerError.oauthTokenExchangeFailed("invalid endpoint")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = self.formURLEncoded(parameters: parameters)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AntigravityAccountManagerError.oauthTokenExchangeFailed(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AntigravityAccountManagerError.oauthTokenExchangeFailed("invalid response")
        }
        guard (200...299).contains(http.statusCode) else {
            let details = String(bytes: data, encoding: .utf8) ?? ""
            throw AntigravityAccountManagerError.oauthTokenExchangeFailed(
                "HTTP \(http.statusCode): \(details)")
        }
        return data
    }

    private static func formURLEncoded(parameters: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let query = parameters
            .sorted(by: { $0.key < $1.key })
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
        return Data(query.utf8)
    }

    private static func injectCredential(_ credential: AntigravityOAuthCredential, databaseURL: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            let message = self.sqliteErrorMessage(db)
            if db != nil { sqlite3_close(db) }
            throw AntigravityAccountManagerError.databaseOpenFailed(message)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1200)

        let expiry = Int64(max(credential.accessTokenExpiry.timeIntervalSince1970, 0))
        let newPayload = self.buildUnifiedOAuthPayload(
            accessToken: credential.accessToken,
            refreshToken: credential.refreshToken,
            expiryTimestamp: expiry)

        var wroteAtLeastOne = false
        var errors: [String] = []
        do {
            try self.writeItemValue(db: db, key: self.unifiedOAuthKey, value: newPayload)
            wroteAtLeastOne = true
        } catch {
            errors.append("new-format: \(error.localizedDescription)")
        }

        if let legacyCurrent = self.readItemValue(db: db, key: self.legacyOAuthKey),
           !legacyCurrent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            do {
                let legacyPayload = try self.buildLegacyOAuthPayload(
                    currentBase64: legacyCurrent,
                    email: credential.email,
                    accessToken: credential.accessToken,
                    refreshToken: credential.refreshToken,
                    expiryTimestamp: expiry)
                try self.writeItemValue(db: db, key: self.legacyOAuthKey, value: legacyPayload)
                wroteAtLeastOne = true
            } catch {
                errors.append("legacy-format: \(error.localizedDescription)")
            }
        }

        guard wroteAtLeastOne else {
            throw AntigravityAccountManagerError.databaseWriteFailed(errors.joined(separator: " | "))
        }
        try self.writeItemValue(db: db, key: self.onboardingKey, value: "true")
    }

    private static func buildUnifiedOAuthPayload(
        accessToken: String,
        refreshToken: String,
        expiryTimestamp: Int64) -> String
    {
        let oauthInfo = self.createOAuthInfoMessage(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiryTimestamp: expiryTimestamp)
        let oauthInfoBase64 = Data(oauthInfo).base64EncodedString()
        let inner2 = self.encodeStringField(fieldNumber: 1, value: oauthInfoBase64)
        let inner1 = self.encodeStringField(fieldNumber: 1, value: "oauthTokenInfoSentinelKey")
        let inner = inner1 + self.encodeLengthDelimitedField(fieldNumber: 2, payload: inner2)
        let outer = self.encodeLengthDelimitedField(fieldNumber: 1, payload: inner)
        return Data(outer).base64EncodedString()
    }

    private static func buildLegacyOAuthPayload(
        currentBase64: String,
        email: String,
        accessToken: String,
        refreshToken: String,
        expiryTimestamp: Int64) throws -> String
    {
        guard let currentData = Data(base64Encoded: currentBase64) else {
            throw AntigravityAccountManagerError.databaseWriteFailed("legacy base64 decode failed")
        }

        var cleanBytes = try self.removeField(1, from: Array(currentData))
        cleanBytes = try self.removeField(2, from: cleanBytes)
        cleanBytes = try self.removeField(6, from: cleanBytes)
        let emailField = self.createEmailField(email: email)
        let oauthField = self.createOAuthField(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiryTimestamp: expiryTimestamp)
        let merged = cleanBytes + emailField + oauthField
        return Data(merged).base64EncodedString()
    }

    private static func createOAuthInfoMessage(
        accessToken: String,
        refreshToken: String,
        expiryTimestamp: Int64) -> [UInt8]
    {
        let accessField = self.encodeStringField(fieldNumber: 1, value: accessToken)
        let typeField = self.encodeStringField(fieldNumber: 2, value: "Bearer")
        let refreshField = self.encodeStringField(fieldNumber: 3, value: refreshToken)
        let timestampFieldTag = self.encodeVarint(UInt64((1 << 3) | 0))
        let timestampMessage = timestampFieldTag + self.encodeVarint(UInt64(max(0, expiryTimestamp)))
        let expiryField = self.encodeLengthDelimitedField(fieldNumber: 4, payload: timestampMessage)
        return accessField + typeField + refreshField + expiryField
    }

    private static func createOAuthField(
        accessToken: String,
        refreshToken: String,
        expiryTimestamp: Int64) -> [UInt8]
    {
        let oauthMessage = self.createOAuthInfoMessage(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiryTimestamp: expiryTimestamp)
        return self.encodeLengthDelimitedField(fieldNumber: 6, payload: oauthMessage)
    }

    private static func createEmailField(email: String) -> [UInt8] {
        self.encodeStringField(fieldNumber: 2, value: email)
    }

    private static func encodeStringField(fieldNumber: Int, value: String) -> [UInt8] {
        self.encodeLengthDelimitedField(fieldNumber: fieldNumber, payload: Array(value.utf8))
    }

    private static func encodeLengthDelimitedField(fieldNumber: Int, payload: [UInt8]) -> [UInt8] {
        let tag = UInt64((fieldNumber << 3) | 2)
        return self.encodeVarint(tag) + self.encodeVarint(UInt64(payload.count)) + payload
    }

    private static func encodeVarint(_ value: UInt64) -> [UInt8] {
        var current = value
        var buffer: [UInt8] = []
        while current >= 0x80 {
            buffer.append(UInt8((current & 0x7F) | 0x80))
            current >>= 7
        }
        buffer.append(UInt8(current))
        return buffer
    }

    private static func readVarint(_ bytes: [UInt8], offset: Int) throws -> (UInt64, Int) {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var index = offset
        while true {
            guard index < bytes.count else {
                throw AntigravityAccountManagerError.databaseWriteFailed("protobuf varint truncated")
            }
            let byte = bytes[index]
            result |= UInt64(byte & 0x7F) << shift
            index += 1
            if byte & 0x80 == 0 {
                return (result, index)
            }
            shift += 7
            if shift >= 64 {
                throw AntigravityAccountManagerError.databaseWriteFailed("protobuf varint overflow")
            }
        }
    }

    private static func skipField(_ bytes: [UInt8], offset: Int, wireType: UInt8) throws -> Int {
        switch wireType {
        case 0:
            let (_, nextOffset) = try self.readVarint(bytes, offset: offset)
            return nextOffset
        case 1:
            return offset + 8
        case 2:
            let (length, contentOffset) = try self.readVarint(bytes, offset: offset)
            let next = contentOffset + Int(length)
            guard next <= bytes.count else {
                throw AntigravityAccountManagerError.databaseWriteFailed("protobuf length exceeds data")
            }
            return next
        case 5:
            return offset + 4
        default:
            throw AntigravityAccountManagerError.databaseWriteFailed("unsupported protobuf wire type \(wireType)")
        }
    }

    private static func removeField(_ fieldNumber: UInt32, from bytes: [UInt8]) throws -> [UInt8] {
        var result: [UInt8] = []
        var offset = 0
        while offset < bytes.count {
            let start = offset
            let (tag, nextOffset) = try self.readVarint(bytes, offset: offset)
            let wireType = UInt8(tag & 0x7)
            let currentField = UInt32(tag >> 3)
            let fieldEnd = try self.skipField(bytes, offset: nextOffset, wireType: wireType)
            if currentField != fieldNumber {
                result.append(contentsOf: bytes[start..<fieldEnd])
            }
            offset = fieldEnd
        }
        return result
    }

    private static func resolveDatabaseURL() async throws -> URL {
        if let processDerived = await self.databaseURLFromRunningProcess(),
           FileManager.default.fileExists(atPath: processDerived.path)
        {
            return processDerived
        }
        let fallback = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Antigravity/User/globalStorage/state.vscdb")
        if FileManager.default.fileExists(atPath: fallback.path) {
            return fallback
        }
        throw AntigravityAccountManagerError.databaseNotFound
    }

    private static func databaseURLFromRunningProcess() async -> URL? {
        guard let commandLine = await self.currentAntigravityLanguageServerCommandLine() else {
            return nil
        }
        if let userDataDir = self.extractFlag("--user-data-dir", from: commandLine) {
            return URL(fileURLWithPath: userDataDir)
                .appendingPathComponent("User/globalStorage/state.vscdb")
        }
        if let appDataDir = self.extractFlag("--app_data_dir", from: commandLine) {
            let root = URL(fileURLWithPath: appDataDir)
            let direct = root.appendingPathComponent("state.vscdb")
            if FileManager.default.fileExists(atPath: direct.path) {
                return direct
            }
            return root.appendingPathComponent("User/globalStorage/state.vscdb")
        }
        return nil
    }

    private static func currentAntigravityLanguageServerCommandLine() async -> String? {
        guard let output = try? await self.runCommand(
            binary: "/bin/ps",
            arguments: ["-ax", "-o", "command="],
            timeout: 6,
            tolerateFailure: false)
        else {
            return nil
        }
        for line in output.split(separator: "\n") {
            let command = String(line)
            let lower = command.lowercased()
            guard lower.contains("language_server_macos") else { continue }
            guard lower.contains("antigravity") else { continue }
            return command
        }
        return nil
    }

    private static func extractFlag(_ flag: String, from commandLine: String) -> String? {
        let pattern = "\(NSRegularExpression.escapedPattern(for: flag))(?:=|\\s+)(\"[^\"]+\"|'[^']+'|\\S+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        let range = NSRange(commandLine.startIndex..<commandLine.endIndex, in: commandLine)
        guard let match = regex.firstMatch(in: commandLine, options: [], range: range),
              let valueRange = Range(match.range(at: 1), in: commandLine)
        else {
            return nil
        }
        var value = String(commandLine[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func readItemValue(db: OpaquePointer?, key: String) -> String? {
        let sql = "SELECT value FROM ItemTable WHERE key = ? LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let bindKeyResult = key.withCString { cKey in
            sqlite3_bind_text(statement, 1, cKey, -1, transient)
        }
        guard bindKeyResult == SQLITE_OK else { return nil }

        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard let cValue = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: cValue)
    }

    private static func writeItemValue(db: OpaquePointer?, key: String, value: String) throws {
        let sql = "INSERT OR REPLACE INTO ItemTable (key, value) VALUES (?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw AntigravityAccountManagerError.databaseWriteFailed(self.sqliteErrorMessage(db))
        }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let bindKeyResult = key.withCString { cKey in
            sqlite3_bind_text(statement, 1, cKey, -1, transient)
        }
        guard bindKeyResult == SQLITE_OK else {
            throw AntigravityAccountManagerError.databaseWriteFailed(self.sqliteErrorMessage(db))
        }
        let bindValueResult = value.withCString { cValue in
            sqlite3_bind_text(statement, 2, cValue, -1, transient)
        }
        guard bindValueResult == SQLITE_OK else {
            throw AntigravityAccountManagerError.databaseWriteFailed(self.sqliteErrorMessage(db))
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw AntigravityAccountManagerError.databaseWriteFailed(self.sqliteErrorMessage(db))
        }
    }

    private static func sqliteErrorMessage(_ db: OpaquePointer?) -> String {
        guard let db, let cString = sqlite3_errmsg(db) else { return "unknown" }
        return String(cString: cString)
    }

    @discardableResult
    private static func runCommand(
        binary: String,
        arguments: [String],
        timeout: TimeInterval,
        tolerateFailure: Bool) async throws -> String
    {
        let label = "antigravity-\(URL(fileURLWithPath: binary).lastPathComponent)"
        do {
            let result = try await SubprocessRunner.run(
                binary: binary,
                arguments: arguments,
                environment: ProcessInfo.processInfo.environment,
                timeout: timeout,
                label: label)
            return result.stdout
        } catch {
            if tolerateFailure {
                return ""
            }
            if let wrapped = error as? SubprocessRunnerError,
               let description = wrapped.errorDescription
            {
                throw AntigravityAccountManagerError.databaseWriteFailed(description)
            }
            throw AntigravityAccountManagerError.databaseWriteFailed(error.localizedDescription)
        }
    }
}

// swiftlint:enable type_body_length
