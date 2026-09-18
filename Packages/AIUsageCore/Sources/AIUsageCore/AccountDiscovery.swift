import CryptoKit
import Foundation

public struct DiscoveredAccount: Sendable, Hashable {
    public var provider: ProviderKind
    public var path: String
}

public enum AccountDiscovery {
    /// `~/.claude-*` 중 `.claude.json` 이 있는 것, `~/.codex-*` 중 `auth.json` 이 있는 것.
    /// 순서: one, two, three… 숫자 단어 먼저, 나머지는 이름순.
    public static func discover(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [DiscoveredAccount] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        var result: [DiscoveredAccount] = []
        for p in ProviderKind.allCases {
            let prefix = p == .claude ? ".claude-" : ".codex-"
            let marker = p == .claude ? ".claude.json" : "auth.json"
            let dirs = names.filter { $0.hasPrefix(prefix) }
                .filter { FileManager.default.fileExists(atPath: home.appendingPathComponent($0).appendingPathComponent(marker).path) }
                .sorted { sortKey(String($0.dropFirst(prefix.count))) < sortKey(String($1.dropFirst(prefix.count))) }
            result += dirs.map { DiscoveredAccount(provider: p, path: home.appendingPathComponent($0).path) }
        }
        return result
    }

    static let numberWords = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]

    static func sortKey(_ suffix: String) -> String {
        if let i = numberWords.firstIndex(of: suffix) { return "0\(i)" }
        return "1" + suffix
    }

    /// `~/.claude-two` → `cld2`, `~/.codex-lms` → `cdx-lms`
    public static func defaultLabel(provider: ProviderKind, path: String) -> String {
        let base = (path as NSString).lastPathComponent
        let suffix = base.split(separator: "-", maxSplits: 1).dropFirst().first.map(String.init) ?? base
        if let i = numberWords.firstIndex(of: suffix) { return "\(provider.labelPrefix)\(i + 1)" }
        return "\(provider.labelPrefix)-\(suffix)"
    }

    /// Claude Code 가 쓰는 키체인 서비스명: `Claude Code-credentials-<sha256(절대경로) 앞 8 hex>`
    public static func claudeKeychainService(configDir: String) -> String {
        let hash = SHA256.hash(data: Data(configDir.utf8)).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-\(hash.prefix(8))"
    }
}
