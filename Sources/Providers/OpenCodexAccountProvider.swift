import Foundation

/// **Yong fork:** ChatGPT accounts kept by opencodex beside Codex's own login.
///
/// opencodex holds extra ChatGPT logins in `~/.opencodex/codex-accounts.json`
/// and records each one's limits, from the response headers of requests it
/// already makes, in `codex-quota-cache.json`. This reads only those files:
/// no request, no token sent anywhere. The token is opened locally for the
/// address and plan in its claims, exactly as `CodexCredentials.account` does.
enum OpenCodexAccounts {
    struct Entry: Equatable {
        let key: String
        let email: String?
        let plan: String?
    }

    static var directory: URL {
        CodexProfile.homeDirectory.appendingPathComponent(".opencodex", isDirectory: true)
    }
    static var accountsURL: URL { directory.appendingPathComponent("codex-accounts.json") }
    static var quotaURL: URL { directory.appendingPathComponent("codex-quota-cache.json") }

    /// The accounts besides the main Codex login: not deleted in opencodex, and
    /// not the main login filed a second time.
    static func extraAccounts(accounts: Data, mainAuth: Data?) -> [Entry] {
        guard let root = try? JSONSerialization.jsonObject(with: accounts) as? [String: Any]
        else { return [] }
        let mainAccountID = mainAuth
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { ($0["tokens"] as? [String: Any])?["access_token"] as? String }
            .flatMap(CodexCredentials.claims(inJWT:))
            .flatMap { ($0["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_account_id"] as? String }

        return root.keys.sorted().compactMap { key -> Entry? in
            guard let account = root[key] as? [String: Any],
                  account["deletedAt"] == nil || account["deletedAt"] is NSNull,
                  let credential = account["credential"] as? [String: Any] else { return nil }
            if let mainAccountID, credential["chatgptAccountId"] as? String == mainAccountID {
                return nil
            }
            let claims = (credential["accessToken"] as? String).flatMap(CodexCredentials.claims(inJWT:))
            let email = (claims?["https://api.openai.com/profile"] as? [String: Any])?["email"] as? String
            let plan = (claims?["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_plan_type"] as? String
            return Entry(key: key, email: email, plan: plan)
        }
    }

    static func extraAccounts() -> [Entry] {
        guard let accounts = try? Data(contentsOf: accountsURL) else { return [] }
        return extraAccounts(accounts: accounts,
                             mainAuth: try? Data(contentsOf: CodexProfile.default().authURL))
    }

    /// `ssyo**`: the first four characters of the address's local part.
    static func masked(_ email: String?) -> String {
        guard let email, let local = email.split(separator: "@").first else { return "?" }
        return "\(local.prefix(4))**"
    }

    static func planName(_ raw: String?) -> String? {
        switch raw {
        case "prolite": return "Pro 5x"
        case "pro":     return "Pro"
        case let plan?: return plan.prefix(1).uppercased() + plan.dropFirst()
        case nil:       return nil
        }
    }

    /// One account's entry in the quota cache, as the windows Codex's own
    /// provider produces: `primary` the short window, `secondary` the week. A
    /// window whose reset has passed reads 0%, as the status line shows it.
    static func windows(quota: [String: Any], now: Date) -> [LimitWindow] {
        func window(id: String, percent: String, resetAt: String, seconds: Double) -> LimitWindow? {
            guard let used = (quota[percent] as? NSNumber)?.doubleValue else { return nil }
            var resets = (quota[resetAt] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            var fraction = used / 100
            if let reset = resets, reset <= now {
                fraction = 0
                resets = nil
            }
            return LimitWindow(id: id,
                               label: CodexUsage.label(windowSeconds: seconds, fallback: id),
                               usedFraction: fraction, resetsAt: resets, duration: seconds)
        }
        let short = (quota["shortWindowSeconds"] as? NSNumber)?.doubleValue ?? 5 * 3600
        return [window(id: "primary", percent: "shortPercent", resetAt: "shortResetAt", seconds: short),
                window(id: "secondary", percent: "weeklyPercent", resetAt: "weeklyResetAt", seconds: 7 * 86400)]
            .compactMap { $0 }
    }
}

actor OpenCodexAccountProvider: UsageProvider {
    nonisolated let id: String
    nonisolated let displayName: String
    nonisolated let glyph = ProviderGlyph.openai
    nonisolated let entry: OpenCodexAccounts.Entry
    private let quotaURL: URL

    /// opencodex refreshes an account's entry whenever it routes a request
    /// through it. Older than this, the ring is drawn dimmed and dated.
    static let freshFor: TimeInterval = 6 * 3600

    init(entry: OpenCodexAccounts.Entry, quotaURL: URL = OpenCodexAccounts.quotaURL) {
        self.entry = entry
        self.id = "opencodex-\(entry.key)"
        self.displayName = "GPT \(OpenCodexAccounts.masked(entry.email))"
        self.quotaURL = quotaURL
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        guard let data = try? Data(contentsOf: quotaURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let quota = (root["quotas"] as? [String: Any])?[entry.key] as? [String: Any]
        else { throw UsageProviderError.needsAuth }
        let now = Date()
        let windows = OpenCodexAccounts.windows(quota: quota, now: now)
        guard !windows.isEmpty else {
            throw UsageProviderError.nothingMetered("opencodex has no limits recorded for this account yet.")
        }
        let updated = (quota["updatedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        let status: ProviderStatus = updated.map {
            now.timeIntervalSince($0) > Self.freshFor ? .stale(since: $0) : .ok
        } ?? .ok
        return ProviderSnapshot(
            id: id, displayName: displayName, glyph: glyph,
            fidelity: .official, status: status, windows: windows,
            headlineID: windows.contains { $0.id == "primary" } ? "primary" : "secondary",
            weeklyID: "secondary",
            plan: OpenCodexAccounts.planName(entry.plan)
        )
    }

    nonisolated func account() -> ProviderAccount? {
        ProviderAccount(label: OpenCodexAccounts.masked(entry.email),
                        plan: OpenCodexAccounts.planName(entry.plan),
                        source: "opencodex",
                        manageURL: URL(string: "https://chatgpt.com/#settings/Account"))
    }

    nonisolated var signInRoute: SignInRoute { .guidance("Added and signed in through opencodex.") }
    func signOut() async {}
    nonisolated func presentSignIn() {}
    nonisolated func forgetCachedCredential() {}
}
