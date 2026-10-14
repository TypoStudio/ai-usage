import AIUsageCore
import Foundation

/// Antigravity CLI(`agy`) 사용량.
///
/// - 토큰: agy 가 키체인(service `gemini`, account `antigravity`)에 go-keyring 형식으로 둔다
///   (`go-keyring-base64:` 접두사 + base64 JSON `{token:{access_token,refresh_token,expiry}, id_token}`).
///   `~/.gemini/oauth_creds.json` 은 agy 가 갱신하지 않는 옛 파일이라 읽지 않는다.
/// - 갱신: Google 갱신 토큰은 1회용이 아니라 메모리에서 갱신해도 agy 와 경쟁하지 않는다. 새 액세스 토큰은
///   앱 전용 키체인 항목에만 두고 agy 의 항목은 건드리지 않는다. 클라이언트 비밀은 저장소에 넣지 않고
///   설치된 agy 바이너리에서 읽는다.
/// - 쿼터: `loadCodeAssist` 로 받은 `cloudaicompanionProject` 를 넣어 `retrieveUserQuotaSummary` 를 부른다.
///   프로젝트 없이 부르면 403(#3501 SUBSCRIPTION_REQUIRED). User-Agent 에 `antigravity` 가 있어야 한다.
public enum AntigravityFetcher {
    static let api = "https://daily-cloudcode-pa.googleapis.com/v1internal"
    static let tokenURL = "https://oauth2.googleapis.com/token"
    static let cacheService = "AI Usage-antigravity-token"

    struct Token: Sendable {
        var access: String
        var refresh: String?
        var expiresAt: Date
        var clientID: String?
        var email: String?
    }

    /// 우리가 갱신한 액세스 토큰과, 그때 통한 클라이언트 비밀 (바이너리에 둘이 들어 있어 맞는 것을 기억한다)
    struct Cached: Codable { var access: String; var expiresAt: Date; var clientSecret: String? }

    enum Failure: Error, CustomStringConvertible {
        case noRefreshToken, noClientSecret, http(Int)
        var description: String {
            switch self {
            case .noRefreshToken: return String(localized: "갱신 토큰 없음")
            case .noClientSecret: return String(localized: "agy 실행 파일을 찾지 못해 토큰을 갱신할 수 없습니다")
            case let .http(status): return String(localized: "서버 응답 \(status)")
            }
        }
    }

    public static func version(agyPath: String?) async -> String {
        guard let agyPath else { return "1.3.4" }
        let r = await Shell.run(agyPath, ["--version"], timeout: 10)
        let v = String(decoding: r.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? "1.3.4" : v
    }

    public static func fetch(dir: String, version: String) async -> FetchOutcome {
        guard var token = await readToken() else {
            return .expired(String(localized: "agy 로그인 정보가 없습니다 — 터미널에서 agy 를 실행해 로그인하세요"), email: nil, raw: nil)
        }
        if token.expiresAt.timeIntervalSinceNow < 60 {
            do { token = try await refresh(token, dir: dir) } catch {
                return .expired(String(localized: "토큰 갱신 실패 — \(String(describing: error))"), email: token.email, raw: nil)
            }
        }
        let headers = ["Authorization": "Bearer \(token.access)", "Accept": "application/json",
                       "User-Agent": "antigravity/\(version) darwin/arm64"]
        do {
            let meta = try JSONSerialization.data(withJSONObject: ["metadata": ["ideType": "ANTIGRAVITY", "platform": "DARWIN_ARM64", "pluginType": "GEMINI"]])
            let (load, s1) = try await HTTP.post("\(api):loadCodeAssist", body: meta, headers: headers)
            if s1 == 429 { return .rateLimited(email: token.email) }
            if s1 == 401 || s1 == 403 { return .expired(String(localized: "인증 실패(\(s1))"), email: token.email, raw: load) }
            let info = (try? JSONSerialization.jsonObject(with: load) as? [String: Any]) ?? [:]
            let project = info["cloudaicompanionProject"] as? String ?? ""
            let plan = (info["currentTier"] as? [String: Any])?["name"] as? String
            let (data, status) = try await HTTP.post("\(api):retrieveUserQuotaSummary", json: ["project": project], headers: headers)
            if status == 429 { return .rateLimited(email: token.email) }
            if status == 401 || status == 403 { return .expired(String(localized: "인증 실패(\(status))"), email: token.email, raw: data) }
            do {
                return .ok(try UsageParser.parseAntigravity(data, plan: plan), email: token.email, raw: data)
            } catch {
                return .failed("\(error)", email: token.email, raw: data)
            }
        } catch {
            return .failed(error.localizedDescription, email: token.email, raw: nil)
        }
    }

    static func readToken() async -> Token? {
        guard let blob = await AppKeychain.read(service: "gemini", account: "antigravity") else { return nil }
        var raw = String(decoding: blob, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "go-keyring-base64:"
        if raw.hasPrefix(prefix), let d = Data(base64Encoded: String(raw.dropFirst(prefix.count))) {
            raw = String(decoding: d, as: UTF8.self)
        }
        guard let o = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let t = o["token"] as? [String: Any], let access = t["access_token"] as? String else { return nil }
        let idToken = o["id_token"] as? String
        var token = Token(access: access, refresh: t["refresh_token"] as? String,
                          expiresAt: (t["expiry"] as? String).flatMap(UsageParser.parseISO) ?? .distantPast,
                          clientID: idToken.flatMap { UsageParser.jwtPayload($0)?["aud"] as? String },
                          email: idToken.flatMap(UsageParser.emailFromJWT))
        // 우리가 갱신해 둔 토큰이 더 새것이면 그걸 쓴다
        if let data = await AppKeychain.read(service: cacheService, account: "antigravity"),
           let cached = try? decoder.decode(Cached.self, from: data), cached.expiresAt > token.expiresAt {
            token.access = cached.access
            token.expiresAt = cached.expiresAt
        }
        return token
    }

    static func refresh(_ token: Token, dir: String) async throws -> Token {
        guard let refresh = token.refresh, let clientID = token.clientID else { throw Failure.noRefreshToken }
        var candidates = await clientSecrets()
        if let data = await AppKeychain.read(service: cacheService, account: "antigravity"),
           let known = (try? decoder.decode(Cached.self, from: data))?.clientSecret {
            candidates.removeAll { $0 == known }
            candidates.insert(known, at: 0)
        }
        guard !candidates.isEmpty else { throw Failure.noClientSecret }
        var lastStatus = 0
        for secret in candidates {
            var c = URLComponents()
            c.queryItems = [.init(name: "client_id", value: clientID), .init(name: "client_secret", value: secret),
                            .init(name: "refresh_token", value: refresh), .init(name: "grant_type", value: "refresh_token")]
            let (data, status) = try await HTTP.post(tokenURL, body: Data((c.percentEncodedQuery ?? "").utf8),
                                                     contentType: "application/x-www-form-urlencoded")
            lastStatus = status
            guard status == 200, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = o["access_token"] as? String, let expires = (o["expires_in"] as? NSNumber)?.doubleValue else {
                if status == 401 { continue }   // invalid_client: 다른 비밀로
                throw Failure.http(status)
            }
            var fresh = token
            fresh.access = access
            fresh.expiresAt = Date().addingTimeInterval(expires)
            if let d = try? encoder.encode(Cached(access: access, expiresAt: fresh.expiresAt, clientSecret: secret)) {
                _ = await AppKeychain.write(service: cacheService, account: "antigravity", data: d)
            }
            return fresh
        }
        throw Failure.http(lastStatus)
    }

    /// 설치 앱 OAuth 클라이언트 비밀 후보 — agy 바이너리 안의 `GOCSPX-…` 문자열(둘). 저장소에 넣지 않는다.
    static func clientSecrets() async -> [String] {
        guard let agy = Shell.locate("agy", override: nil) else { return [] }
        let r = await Shell.run("/usr/bin/grep", ["-a", "-o", "GOCSPX-[A-Za-z0-9_-]\\{28\\}", agy], timeout: 60)
        var seen: [String] = []
        for line in String(decoding: r.stdout, as: UTF8.self).split(separator: "\n") where !seen.contains(String(line)) {
            seen.append(String(line))
        }
        return seen
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }()
}
