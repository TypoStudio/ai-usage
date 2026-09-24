import AIUsageCore
import Foundation

enum HTTP {
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 15
        return URLSession(configuration: c)
    }()

    static func get(_ url: String, headers: [String: String]) async throws -> (Data, Int) {
        var req = URLRequest(url: URL(string: url)!)
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, resp) = try await session.data(for: req)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

/// 한 계정 조회의 결과.
enum FetchOutcome: Sendable {
    case ok(ParsedUsage, email: String?, raw: Data)
    /// 토큰 만료·인증 실패 — 사용자가 CLI 를 한 번 실행해야 한다
    case expired(String, email: String?, raw: Data?)
    /// 429
    case rateLimited(email: String?)
    case failed(String, email: String?, raw: Data?)
    /// 이번엔 건너뜀 (화면이 꺼져 잠자기 직전 등) — 이전 값을 그대로 둔다
    case skipped
}
