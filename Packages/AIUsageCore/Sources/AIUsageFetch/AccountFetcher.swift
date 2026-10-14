import AIUsageCore
import Foundation

/// 계정 하나의 조회 — 앱과 `aiusage` CLI 가 같은 로직을 쓴다.
public enum AccountFetcher {
    public static let loginRequired = String(localized: "로그인이 필요합니다 — ‘로그인’ 을 누르면 이후 앱이 스스로 갱신합니다")

    /// `claude`/`codex` 실행 파일의 버전 — User-Agent 에 쓴다. `override` 는 설정에서 지정한 경로.
    public struct Versions: Sendable {
        public var claude: String
        public var codex: String
        public var agy: String
        public init(claude: String = "2.0.0", codex: String = "0.100.0", agy: String = "1.3.4") {
            self.claude = claude; self.codex = codex; self.agy = agy
        }
    }

    public static func versions(claudePath: String?, codexPath: String?, agyPath: String?) async -> Versions {
        async let c = ClaudeFetcher.version(claudePath: Shell.locate("claude", override: claudePath))
        async let x = CodexFetcher.version(codexPath: Shell.locate("codex", override: codexPath))
        async let a = AntigravityFetcher.version(agyPath: Shell.locate("agy", override: agyPath))
        return await Versions(claude: c, codex: x, agy: a)
    }

    public static func fetch(provider: ProviderKind, dir: String, versions: Versions) async -> FetchOutcome {
        switch provider {
        case .claude: return await fetchClaude(dir: dir, version: versions.claude)
        case .codex: return await CodexFetcher.fetch(dir: dir, version: versions.codex)
        case .antigravity: return await AntigravityFetcher.fetch(dir: dir, version: versions.agy)
        }
    }

    private static func fetchClaude(dir: String, version: String) async -> FetchOutcome {
        let email = ClaudeFetcher.email(dir: dir)
        let cred = await ClaudeFetcher.readCredential(dir: dir)
        // 1) 앱 자체 로그인이 있으면 그 토큰으로 — 만료 5분 전에 미리 갱신하고, 401 이면 한 번 갱신해 다시 시도
        if var token = await ClaudeOAuth.load(dir: dir) {
            var refreshed = false
            if token.needsRefresh {
                switch await refreshAppToken(token, dir: dir, email: email) {
                case let .success(t): token = t; refreshed = true
                case let .failure(f): return f.outcome
                }
            }
            let outcome = await ClaudeFetcher.fetch(token: token.accessToken, subscription: cred?.subscription,
                                                    email: token.email ?? email, version: version)
            guard case .expired = outcome, !refreshed else { return outcome }
            switch await refreshAppToken(token, dir: dir, email: email) {
            case let .success(t):
                return await ClaudeFetcher.fetch(token: t.accessToken, subscription: cred?.subscription,
                                                 email: t.email ?? email, version: version)
            case let .failure(f): return f.outcome
            }
        }
        // 2) 없으면 Claude Code 의 자격 증명을 읽기만 한다. 만료됐으면 앱에서 로그인하라고 안내한다 —
        //    여기서 `claude doctor` 로 갱신하면 Claude Code 와 갱신 토큰을 두고 경쟁해 로그인이 풀린다.
        guard let cred, cred.expiresAt > Date() else { return .expired(loginRequired, email: email, raw: nil) }
        return await ClaudeFetcher.fetch(token: cred.token, subscription: cred.subscription, email: email, version: version)
    }

    private struct RefreshFailure: Error { var outcome: FetchOutcome }

    /// 갱신 실패 시 토큰은 지우지 않는다. 429 는 백오프, invalid_grant 만 재로그인.
    private static func refreshAppToken(_ token: ClaudeOAuth.Token, dir: String, email: String?) async -> Result<ClaudeOAuth.Token, RefreshFailure> {
        do {
            return .success(try await ClaudeOAuth.refresh(token, dir: dir))
        } catch ClaudeOAuth.Failure.invalidGrant {
            return .failure(RefreshFailure(outcome: .expired(loginRequired, email: email, raw: nil)))
        } catch ClaudeOAuth.Failure.http(429, _) {
            return .failure(RefreshFailure(outcome: .rateLimited(email: email)))
        } catch {
            return .failure(RefreshFailure(outcome: .failed(String(localized: "토큰 갱신 실패 — \(String(describing: error))"), email: email, raw: nil)))
        }
    }
}
