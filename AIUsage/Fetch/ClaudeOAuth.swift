import CryptoKit
import Foundation

/// 앱 자체 OAuth 세션 — CLIProxyAPI 가 로그인을 유지하는 방식.
///
/// Claude Code 의 갱신 토큰은 1회용(갱신하면 교체)이다. 앱이 `claude doctor` 로 Claude Code 의 토큰을 갱신하면
/// 다른 Claude Code 프로세스와 같은 토큰을 두고 경쟁하게 되고, 지는 쪽이 `invalid_grant` 를 받으면 Claude Code 는
/// 키체인 자격 증명을 비운다(`accessToken: ""`, `expiresAt: 0` — 2026-09-24 cld2·cld3, 2026-10-10 cld2).
/// 그래서 앱은 자기 토큰 체인을 따로 갖고(한 번 로그인), Claude Code 의 키체인은 읽기만 한다.
enum ClaudeOAuth {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let authorizeURL = "https://claude.ai/oauth/authorize"
    /// `console.anthropic.com/v1/oauth/token` 은 429 를 돌려준다 — Claude Code 2.1 도 이 주소를 쓴다
    static let tokenURL = "https://platform.claude.com/v1/oauth/token"
    /// 브라우저가 코드를 화면에 보여 주는 리다이렉트 — 사용자가 복사해 앱에 붙인다
    static let redirectURI = "https://platform.claude.com/oauth/code/callback"
    static let scope = "user:profile user:inference"
    static let keychainService = "AI Usage-claude-oauth"
    /// 만료 5분 전부터 미리 갱신 (CLIProxyAPI 와 같다)
    static let refreshLead: TimeInterval = 300

    struct Token: Codable, Sendable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
        var email: String?
        var needsRefresh: Bool { expiresAt.timeIntervalSinceNow < refreshLead }
    }

    struct Login: Sendable {
        var url: URL
        var verifier: String
        var state: String
    }

    enum Failure: Error, CustomStringConvertible {
        case http(Int, String), invalidGrant, badCode, badResponse, keychain(Int32)
        var description: String {
            switch self {
            case let .http(status, msg): return String(localized: "서버 응답 \(status): \(msg)")
            case .invalidGrant: return String(localized: "갱신 토큰이 무효화되었습니다")
            case .badCode: return String(localized: "코드 형식이 맞지 않습니다 — 브라우저에 표시된 코드를 그대로 붙여 넣으세요")
            case .badResponse: return String(localized: "토큰 응답을 읽을 수 없습니다")
            case let .keychain(status): return String(localized: "키체인 저장 실패 (\(status))")
            }
        }
    }

    // MARK: 로그인 (PKCE)

    static func beginLogin() -> Login {
        let verifier = randomURLSafe()
        let state = randomURLSafe()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        var c = URLComponents(string: authorizeURL)!
        c.queryItems = [
            .init(name: "code", value: "true"), .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"), .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: scope), .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"), .init(name: "state", value: state),
        ]
        return Login(url: c.url!, verifier: verifier, state: state)
    }

    /// 브라우저가 보여 준 `코드#state` 를 토큰으로 바꿔 저장한다.
    static func finishLogin(_ login: Login, pasted: String, dir: String) async throws -> Token {
        let parts = pasted.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "#", maxSplits: 1).map(String.init)
        guard let code = parts.first, !code.isEmpty, parts.count < 2 || parts[1] == login.state else { throw Failure.badCode }
        let token = try await post([
            "grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI,
            "client_id": clientID, "code_verifier": login.verifier, "state": login.state,
        ], previousRefresh: nil)
        try await save(token, dir: dir)
        return token
    }

    /// 실패해도 저장된 토큰은 지우지 않는다 — 일시 오류면 다음 주기에 다시 시도한다.
    static func refresh(_ old: Token, dir: String) async throws -> Token {
        var fresh = try await post([
            "grant_type": "refresh_token", "refresh_token": old.refreshToken, "client_id": clientID, "scope": scope,
        ], previousRefresh: old.refreshToken)
        fresh.email = fresh.email ?? old.email
        try await save(fresh, dir: dir)
        return fresh
    }

    private static func post(_ body: [String: String], previousRefresh: String?) async throws -> Token {
        let (data, status) = try await HTTP.post(tokenURL, json: body, headers: [
            "Accept": "application/json, text/plain, */*", "User-Agent": "axios/1.15.2",
        ])
        let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard status == 200 else {
            if status == 400, o?["error"] as? String == "invalid_grant" { throw Failure.invalidGrant }
            let msg = o?["error_description"] as? String ?? o?["error"] as? String ?? String(decoding: data.prefix(200), as: UTF8.self)
            throw Failure.http(status, msg)
        }
        guard let o, let access = o["access_token"] as? String, let expires = (o["expires_in"] as? NSNumber)?.doubleValue else {
            throw Failure.badResponse
        }
        let refresh = (o["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? previousRefresh ?? ""
        let email = (o["account"] as? [String: Any])?["email_address"] as? String
        return Token(accessToken: access, refreshToken: refresh, expiresAt: Date().addingTimeInterval(expires), email: email)
    }

    // MARK: 저장 — 앱 전용 키체인 항목(계정 = 설정 디렉토리). Claude Code 의 항목은 건드리지 않는다.
    // `security -i` 에 명령을 stdin 으로 넘기고 비밀은 hex 로 적어 ps·따옴표 문제를 피한다.

    static func load(dir: String) async -> Token? {
        let r = await Shell.run("/usr/bin/security", ["find-generic-password", "-s", keychainService, "-a", dir, "-w"], timeout: 10)
        guard r.status == 0 else { return nil }
        return try? decoder.decode(Token.self, from: r.stdout)
    }

    static func save(_ token: Token, dir: String) async throws {
        let hex = try encoder.encode(token).map { String(format: "%02x", $0) }.joined()
        let cmd = "add-generic-password -U -a \"\(dir)\" -s \"\(keychainService)\" -X \(hex)\n"
        let r = await Shell.run("/usr/bin/security", ["-i"], input: Data(cmd.utf8), timeout: 15)
        guard r.status == 0 else { throw Failure.keychain(r.status) }
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }()

    private static func randomURLSafe() -> String {
        Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }).base64URL
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
