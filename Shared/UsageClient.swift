import Foundation
import Security

struct UsageClient {
    var session: URLSession = .shared
    var codexAuthURL: URL = ConfigLocation.codexAuthURL
    var claudeCodeAuth = ClaudeCodeAuth()

    func fetch(config: WidgetConfig) async -> UsageSnapshot {
        async let claude = fetchClaude(config)
        async let codex = fetchCodex(config)
        return await UsageSnapshot(date: Date(), claude: claude, codex: codex)
    }

    private func get(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw UsageError.invalidResponse }
        guard response.statusCode == 200 else { throw UsageError.http(response.statusCode) }
        return data
    }

    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    func fetchClaude(_ config: WidgetConfig) async -> ProviderUsage {
        guard config.claudeEnabled != false else { return ProviderUsage(name: "Claude", isEnabled: false) }
        var failure: Error = UsageError.missingClaude
        if let token = config.oauthToken?.nonempty {
            do { return try await claudeOAuth(token) } catch { failure = error }
        }
        if config.claudeCodeEnabled != false, let token = claudeCodeAuth.token() {
            do {
                guard !token.isExpired else { throw UsageError.claudeCodeExpired }
                return try await claudeOAuth(token.accessToken)
            } catch UsageError.http(401) {
                failure = UsageError.claudeCodeExpired
            } catch { failure = error }
        } else if config.claudeCodeEnabled == false {
            claudeCodeAuth.clearCache()
        }
        if let key = config.sessionKey?.nonempty {
            let org: String
            if let configured = config.organizationId?.nonempty {
                // An organization is a UUID; never interpolate arbitrary path/query characters.
                guard UUID(uuidString: configured) != nil else {
                    return ProviderUsage(name: "Claude", error: "Organization ID must be a UUID.")
                }
                org = configured
            } else {
                do { org = try await organization(sessionKey: key) } catch {
                    return ProviderUsage(name: "Claude", error: error.localizedDescription)
                }
            }
            var req = request(URL(string: "https://claude.ai/api/organizations/\(org)/usage")!)
            req.setValue("sessionKey=\(key)", forHTTPHeaderField: "Cookie")
            do { return try UsageParser.claude(await get(req)) } catch { failure = error }
        }
        return ProviderUsage(name: "Claude", error: failure.localizedDescription)
    }

    private func claudeOAuth(_ token: String) async throws -> ProviderUsage {
        var req = request(URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        return try UsageParser.claude(await get(req))
    }

    /// Looks up the subscription organization for a session key, so users need not copy its UUID.
    func organization(sessionKey: String) async throws -> String {
        var req = request(URL(string: "https://claude.ai/api/organizations")!)
        req.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        return try UsageParser.organization(await get(req))
    }

    func fetchCodex(_ config: WidgetConfig) async -> ProviderUsage {
        guard config.codexEnabled != false else { return ProviderUsage(name: "Codex", isEnabled: false) }
        do {
            let token: String
            let account: String?
            if let manual = config.codexAccessToken?.nonempty {
                token = manual
                account = config.codexAccountId?.nonempty
            } else {
                // Re-read each time so Codex's token rotation and account switches are reflected.
                guard let data = try? Data(contentsOf: codexAuthURL),
                      let auth = try? JSONDecoder().decode(CodexAuth.self, from: data),
                      let access = auth.tokens?.access_token?.nonempty else { throw UsageError.missingCodex }
                token = access
                account = auth.tokens?.account_id?.nonempty
            }
            var req = request(URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let account { req.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id") }
            return try UsageParser.codex(await get(req))
        } catch {
            return ProviderUsage(name: "Codex", error: error.localizedDescription)
        }
    }
}

/// Claude Code's OAuth access token. Claude Code refreshes it while running;
/// this app only reads it and never refreshes or modifies Claude Code's login.
struct ClaudeCodeToken: Codable, Equatable {
    let accessToken: String
    /// Milliseconds since 1970, as stored by Claude Code.
    let expiresAt: Double?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date(timeIntervalSince1970: expiresAt / 1000) <= Date()
    }

    static func parse(_ data: Data) -> ClaudeCodeToken? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = (oauth["accessToken"] as? String)?.nonempty else { return nil }
        return ClaudeCodeToken(accessToken: token, expiresAt: UsageParser.number(oauth["expiresAt"]))
    }
}

struct ClaudeCodeAuth {
    /// Only the host app reads the Keychain (macOS asks once). The sandboxed widget
    /// cannot, so it reads the copy the app caches on each refresh.
    var readsKeychain = false
    var credentialsURL: URL = ConfigLocation.claudeCodeCredentialsURL
    var cacheURL: URL = ConfigLocation.claudeCodeTokenURL

    func token() -> ClaudeCodeToken? {
        guard readsKeychain else { return cached() }
        // Claude Code stores its login in the Keychain on macOS and in a file elsewhere.
        let token = keychainData().flatMap(ClaudeCodeToken.parse)
            ?? (try? Data(contentsOf: credentialsURL)).flatMap(ClaudeCodeToken.parse)
        if let token, token != cached(), let data = try? JSONEncoder().encode(token) {
            try? writePrivately(data, to: cacheURL)
        }
        return token
    }

    func clearCache() {
        guard readsKeychain else { return }
        try? FileManager.default.removeItem(at: cacheURL)
    }

    private func cached() -> ClaudeCodeToken? {
        (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder().decode(ClaudeCodeToken.self, from: $0) }
    }

    private func keychainData() -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "Claude Code-credentials",
                                    kSecMatchLimit as String: kSecMatchLimitOne,
                                    kSecReturnData as String: true]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
}

private struct CodexAuth: Decodable {
    let tokens: Tokens?
    struct Tokens: Decodable {
        let access_token: String?
        let account_id: String?
    }
}

extension String {
    var nonempty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
