import AIUsageCore
import Foundation

enum CodexFetcher {
    static func version(codexPath: String?) async -> String {
        guard let codexPath else { return "0.100.0" }
        let r = await Shell.run(codexPath, ["--version"], timeout: 10)
        let parts = String(decoding: r.stdout, as: UTF8.self).split(whereSeparator: \.isWhitespace)
        return parts.count >= 2 ? String(parts[1]) : "0.100.0"
    }

    static func fetch(dir: String, version: String) async -> FetchOutcome {
        guard let d = FileManager.default.contents(atPath: "\(dir)/auth.json"),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            return .failed(String(localized: "auth.json 없음"), email: nil, raw: nil)
        }
        let tokens = o["tokens"] as? [String: Any] ?? [:]
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
}
