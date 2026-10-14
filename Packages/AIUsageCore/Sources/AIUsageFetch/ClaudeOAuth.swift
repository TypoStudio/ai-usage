import CryptoKit
import Foundation

/// 앱 자체 OAuth 세션 — CLIProxyAPI 가 로그인을 유지하는 방식.
///
/// Claude Code 의 갱신 토큰은 1회용(갱신하면 교체)이다. 앱이 `claude doctor` 로 Claude Code 의 토큰을 갱신하면
/// 다른 Claude Code 프로세스와 같은 토큰을 두고 경쟁하게 되고, 지는 쪽이 `invalid_grant` 를 받으면 Claude Code 는
/// 키체인 자격 증명을 비운다(`accessToken: ""`, `expiresAt: 0` — 2026-09-24 cld2·cld3, 2026-10-10 cld2).
/// 그래서 앱은 자기 토큰 체인을 따로 갖고(한 번 로그인), Claude Code 의 키체인은 읽기만 한다.
public enum ClaudeOAuth {
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

    public struct Token: Codable, Sendable {
        public var accessToken: String
        public var refreshToken: String
        public var expiresAt: Date
        public var email: String?
        public var needsRefresh: Bool { expiresAt.timeIntervalSinceNow < refreshLead }
    }

    public struct Login: Sendable {
        public var url: URL
        var verifier: String
        var state: String
    }

    public enum Failure: Error, CustomStringConvertible {
        case http(Int, String), invalidGrant, badCode, badResponse, keychain(Int32), locked
        public var description: String {
            switch self {
            case let .http(status, msg): return String(localized: "서버 응답 \(status): \(msg)")
            case .invalidGrant: return String(localized: "갱신 토큰이 무효화되었습니다")
            case .badCode: return String(localized: "코드 형식이 맞지 않습니다 — 브라우저에 표시된 코드를 그대로 붙여 넣으세요")
            case .badResponse: return String(localized: "토큰 응답을 읽을 수 없습니다")
            case let .keychain(status): return String(localized: "키체인 저장 실패 (\(status))")
            case .locked: return String(localized: "다른 프로세스가 토큰을 갱신하는 중입니다")
            }
        }
    }

    // MARK: 로그인 (PKCE)

    public static func beginLogin() -> Login {
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
    public static func finishLogin(_ login: Login, pasted: String, dir: String) async throws -> Token {
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
    /// 앱과 `aiusage` CLI 가 같은 토큰을 동시에 갱신하지 않도록 파일 잠금 안에서 돌린다 — 갱신 토큰은 1회용이라
    /// 둘이 같이 쓰면 지는 쪽이 invalid_grant 다. 잠금을 얻은 뒤 다시 읽어 이미 누가 갱신했으면 그 토큰을 쓴다.
    public static func refresh(_ old: Token, dir: String) async throws -> Token {
        let lock = try await FileLock.acquire(lockPath(dir: dir))
        defer { lock.release() }
        if let current = await load(dir: dir), current.expiresAt > old.expiresAt { return current }
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

    public static func load(dir: String) async -> Token? {
        guard let data = await AppKeychain.read(service: keychainService, account: dir) else { return nil }
        return try? decoder.decode(Token.self, from: data)
    }

    public static func save(_ token: Token, dir: String) async throws {
        let status = await AppKeychain.write(service: keychainService, account: dir, data: try encoder.encode(token))
        guard status == 0 else { throw Failure.keychain(status) }
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }()

    private static func lockPath(dir: String) -> String {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AIUsage")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("oauth-\((dir as NSString).lastPathComponent).lock").path
    }

    private static func randomURLSafe() -> String {
        Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }).base64URL
    }
}

/// `flock` 기반 프로세스 간 잠금. 바쁘면 0.5초 간격으로 최대 30초 기다린다.
private struct FileLock {
    let fd: Int32

    static func acquire(_ path: String) async throws -> FileLock {
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw ClaudeOAuth.Failure.locked }
        for _ in 0..<60 {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return FileLock(fd: fd) }
            try await Task.sleep(for: .milliseconds(500))
        }
        close(fd)
        throw ClaudeOAuth.Failure.locked
    }

    func release() {
        flock(fd, LOCK_UN)
        close(fd)
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
