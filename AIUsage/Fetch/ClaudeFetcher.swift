import AIUsageCore
import Foundation

enum ClaudeFetcher {
    struct Credential: Sendable {
        var token: String
        var expiresAt: Date
        var subscription: String?
        /// 갱신 토큰이 남아 있는지. 없으면 `claude doctor` 로도 못 살리고 `/login` 이 필요하다.
        var canRefresh: Bool
    }

    static func email(dir: String) -> String? {
        guard let d = FileManager.default.contents(atPath: "\(dir)/.claude.json"),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return (o["oauthAccount"] as? [String: Any])?["emailAddress"] as? String
    }

    /// 키체인은 `/usr/bin/security` 로 읽는다. Claude Code 가 만든 항목의 ACL 에 이미 들어 있어
    /// 앱을 다시 서명해도 매번 허용 창이 뜨지 않는다. 없으면 `.credentials.json` 폴백.
    static func readCredential(dir: String) async -> Credential? {
        let svc = AccountDiscovery.claudeKeychainService(configDir: dir)
        let r = await Shell.run("/usr/bin/security", ["find-generic-password", "-s", svc, "-w"], timeout: 10)
        var data = r.status == 0 ? r.stdout : Data()
        if data.isEmpty, let file = FileManager.default.contents(atPath: "\(dir)/.credentials.json") { data = file }
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = o["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { return nil }
        let exp = (oauth["expiresAt"] as? NSNumber)?.doubleValue ?? 0
        let refresh = oauth["refreshToken"] as? String ?? ""
        return Credential(token: token, expiresAt: Date(timeIntervalSince1970: exp / 1000),
                          subscription: oauth["subscriptionType"] as? String, canRefresh: !refresh.isEmpty)
    }

    /// 만료된 토큰은 `claude doctor` 가 갱신해 준다 (OAuth 엔드포인트 직접 호출은 429).
    /// 갱신 도중 끊으면 갱신 토큰이 교체된 채 저장되지 않아 로그인이 풀릴 수 있다 → 넉넉히 기다린다.
    static func runDoctor(dir: String, claudePath: String) async {
        _ = await Shell.run(claudePath, ["doctor"], env: ["CLAUDE_CONFIG_DIR": dir], timeout: 90, captureOutput: false)
    }

    static func version(claudePath: String?) async -> String {
        guard let claudePath else { return "2.0.0" }
        let r = await Shell.run(claudePath, ["--version"], timeout: 10)
        return String(decoding: r.stdout, as: UTF8.self).split(separator: " ").first.map(String.init) ?? "2.0.0"
    }

    static func fetch(token: String, subscription: String?, email: String?, version: String) async -> FetchOutcome {
        do {
            let (data, status) = try await HTTP.get("https://api.anthropic.com/api/oauth/usage", headers: [
                "Authorization": "Bearer \(token)",
                "anthropic-beta": "oauth-2025-04-20",
                "User-Agent": "claude-code/\(version)",
            ])
            if status == 429 { return .rateLimited(email: email) }
            if status == 401 || status == 403 {
                return .expired(String(localized: "인증 실패(\(status))"), email: email, raw: data)
            }
            do {
                return .ok(try UsageParser.parseClaude(data, subscriptionType: subscription), email: email, raw: data)
            } catch {
                return .failed("\(error)", email: email, raw: data)
            }
        } catch {
            return .failed(error.localizedDescription, email: email, raw: nil)
        }
    }
}
