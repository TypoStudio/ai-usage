import AIUsageCore
import Foundation

public enum CodexFetcher {
    public static func version(codexPath: String?) async -> String {
        guard let codexPath else { return "0.100.0" }
        let r = await Shell.run(codexPath, ["--version"], timeout: 10)
        let parts = String(decoding: r.stdout, as: UTF8.self).split(whereSeparator: \.isWhitespace)
        return parts.count >= 2 ? String(parts[1]) : "0.100.0"
    }

    public static func fetch(dir: String, version: String) async -> FetchOutcome {
        guard let d = FileManager.default.contents(atPath: "\(dir)/auth.json"),
              let auth = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            return .failed(String(localized: "auth.json 없음"), email: nil, raw: nil)
        }
        let tokens = auth["tokens"] as? [String: Any] ?? [:]
        let outcome = await request(tokens: tokens, version: version)
        // 401/403 이면 codex CLI 와 같은 방식으로 갱신해 auth.json 에 되쓰고 한 번 다시 시도한다
        guard case let .expired(_, email, _) = outcome, let refresh = tokens["refresh_token"] as? String, !refresh.isEmpty else {
            return outcome
        }
        do {
            return await request(tokens: try await refreshTokens(auth: auth, refreshToken: refresh, dir: dir), version: version)
        } catch {
            return .expired(String(localized: "토큰 갱신 실패 — \(String(describing: error))"), email: email, raw: nil)
        }
    }

    private static func request(tokens: [String: Any], version: String) async -> FetchOutcome {
        let email = (tokens["id_token"] as? String).flatMap(UsageParser.emailFromJWT)
        guard let token = tokens["access_token"] as? String else {
            return .failed(String(localized: "ChatGPT 토큰 없음"), email: email, raw: nil)
        }
        do {
            var headers = ["Authorization": "Bearer \(token)", "User-Agent": "codex-cli/\(version)"]
            if let acct = tokens["account_id"] as? String { headers["ChatGPT-Account-Id"] = acct }
            let (data, status) = try await HTTP.get("https://chatgpt.com/backend-api/wham/usage", headers: headers)
            if status == 429 { return .rateLimited(email: email) }
            if status == 401 || status == 403 {
                return .expired(String(localized: "인증 실패(\(status))"), email: email, raw: data)
            }
            do {
                return .ok(try UsageParser.parseCodex(data), email: email, raw: data)
            } catch {
                return .failed("\(error)", email: email, raw: data)
            }
        } catch {
            return .failed(error.localizedDescription, email: email, raw: nil)
        }
    }

    struct RefreshFailure: Error, CustomStringConvertible {
        var status: Int
        var description: String { String(localized: "서버 응답 \(status)") }
    }

    /// codex CLI(`codex-rs/core/src/auth.rs`)의 갱신과 같은 요청·같은 파일 형식. 다른 필드는 그대로 두고
    /// `tokens.*` 와 `last_refresh` 만 바꾼다. 비밀 파일이므로 0600 을 유지한다.
    private static func refreshTokens(auth: [String: Any], refreshToken: String, dir: String) async throws -> [String: Any] {
        let (data, status) = try await HTTP.post("https://auth.openai.com/oauth/token", json: [
            "client_id": "app_EMoamEEZ73f0CkXaXp7hrann", "grant_type": "refresh_token",
            "refresh_token": refreshToken, "scope": "openid profile email",
        ])
        guard status == 200, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = o["access_token"] as? String else { throw RefreshFailure(status: status) }
        var tokens = auth["tokens"] as? [String: Any] ?? [:]
        tokens["access_token"] = access
        if let id = o["id_token"] as? String { tokens["id_token"] = id }
        if let r = o["refresh_token"] as? String, !r.isEmpty { tokens["refresh_token"] = r }
        var auth = auth
        auth["tokens"] = tokens
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        auth["last_refresh"] = f.string(from: Date())
        let path = "\(dir)/auth.json"
        try JSONSerialization.data(withJSONObject: auth, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return tokens
    }
}
