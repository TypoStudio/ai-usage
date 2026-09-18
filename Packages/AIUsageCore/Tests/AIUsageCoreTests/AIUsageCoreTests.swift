import Foundation
import Testing
@testable import AIUsageCore

@Test func claudeLimitsMapToRings() throws {
    let json = """
    {"limits":[
      {"kind":"session","percent":3,"severity":"normal","resets_at":"2026-09-18T05:40:00.234636+00:00","scope":null},
      {"kind":"weekly_all","percent":11,"severity":"normal","resets_at":"2026-09-24T00:00:00.234665+00:00","scope":null},
      {"kind":"weekly_scoped","percent":12,"severity":"warning","resets_at":"2026-09-24T00:00:00+00:00",
       "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}}
    ]}
    """
    let u = try UsageParser.parseClaude(Data(json.utf8), subscriptionType: "max")
    #expect(u.plan == "max")
    #expect(u.limits.map(\.name) == ["session", "weekly_all", "weekly/Fable"])
    #expect(u.limits.map(\.ring) == [.outer, .middle, .inner])
    #expect(u.limits[2].severity == "warning")
    #expect(u.limits[0].severity == nil)
    #expect(u.limits[0].resetsAt == UsageParser.parseISO("2026-09-18T05:40:00.234Z"))
}

@Test func claudeInnerRingFallsBackToFirstScoped() throws {
    let json = """
    {"limits":[{"kind":"weekly_scoped","percent":5,"scope":{"model":{"display_name":"Opus"}}}]}
    """
    let u = try UsageParser.parseClaude(Data(json.utf8), subscriptionType: nil)
    #expect(u.limits.first?.ring == .inner)
}

@Test func claudeErrorBody() {
    let json = #"{"type":"error","error":{"type":"authentication_error","message":"OAuth token has expired."}}"#
    #expect(throws: UsageParseError.invalid("OAuth token has expired.")) {
        try UsageParser.parseClaude(Data(json.utf8), subscriptionType: nil)
    }
}

@Test func codexWindowsMapByLength() throws {
    let json = """
    {"account_id":"ws-1","plan_type":"team",
     "rate_limit":{"primary_window":{"used_percent":100,"limit_window_seconds":604800,"reset_after_seconds":100,"reset_at":1789956101},
                   "secondary_window":{"used_percent":40,"limit_window_seconds":18000,"reset_after_seconds":60}},
     "rate_limit_reached_type":{"type":"workspace_owner_credits_depleted","details":null}}
    """
    let now = Date(timeIntervalSince1970: 1000)
    let u = try UsageParser.parseCodex(Data(json.utf8), now: now)
    #expect(u.plan == "team")
    #expect(u.warning == "workspace_owner_credits_depleted")
    #expect(u.workspaceID == "ws-1")
    #expect(u.limits.map(\.name) == ["5h", "7d"])
    #expect(u.limits.map(\.ring) == [.outer, .middle])
    #expect(u.limits[0].resetsAt == Date(timeIntervalSince1970: 1060))
    #expect(u.limits[1].resetsAt == Date(timeIntervalSince1970: 1789956101))
}

@Test func codexNullSecondary() throws {
    let json = #"{"rate_limit":{"primary_window":{"used_percent":7,"limit_window_seconds":604800},"secondary_window":null}}"#
    let u = try UsageParser.parseCodex(Data(json.utf8))
    #expect(u.limits.count == 1)
    #expect(u.limits[0].resetsAt == nil)
}

@Test func codexErrorDetail() {
    #expect(throws: UsageParseError.invalid("Unauthorized")) {
        try UsageParser.parseCodex(Data(#"{"detail":"Unauthorized"}"#.utf8))
    }
}

@Test func jwtEmail() {
    // {"email":"a@b.com"} → base64url, 패딩 없음
    let payload = Data(#"{"email":"a@b.com"}"#.utf8).base64EncodedString()
        .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    #expect(UsageParser.emailFromJWT("x.\(payload).y") == "a@b.com")
    #expect(UsageParser.emailFromJWT("garbage") == nil)
}

@Test func keychainServiceMatchesClaudeCode() {
    // `printf %s /tmp/x | shasum -a 256 | cut -c1-8` 과 같아야 한다
    let svc = AccountDiscovery.claudeKeychainService(configDir: "/tmp/x")
    #expect(svc == "Claude Code-credentials-2e56aa36")
}

@Test func labels() {
    #expect(AccountDiscovery.defaultLabel(provider: .claude, path: "/Users/a/.claude-two") == "cld2")
    #expect(AccountDiscovery.defaultLabel(provider: .codex, path: "/Users/a/.codex-lms") == "cdx-lms")
}

@Test func discoveryOrderAndMarkers() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    for (dir, file) in [(".claude-lms", ".claude.json"), (".claude-two", ".claude.json"), (".claude-one", ".claude.json"),
                        (".claude-shared", "x"), (".codex-one", "auth.json")] {
        let d = home.appendingPathComponent(dir)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: d.appendingPathComponent(file).path, contents: Data())
    }
    let found = AccountDiscovery.discover(home: home).map { ($0.provider, ($0.path as NSString).lastPathComponent) }
    #expect(found.map(\.1) == [".claude-one", ".claude-two", ".claude-lms", ".codex-one"])
    #expect(found.map(\.0) == [.claude, .claude, .claude, .codex])
}

@Test func remainingFormat() {
    let now = Date(timeIntervalSince1970: 0)
    #expect(UsageFormat.remaining(until: Date(timeIntervalSince1970: 4 * 3600 + 54 * 60), now: now) == "4h 54m")
    #expect(UsageFormat.remaining(until: Date(timeIntervalSince1970: 6 * 86400 + 11 * 3600 + 5), now: now) == "6d 11h")
    #expect(UsageFormat.remaining(until: Date(timeIntervalSince1970: -5), now: now) == "0h 00m")
    #expect(UsageFormat.remaining(until: nil, now: now) == "-")
}

@Test func snapshotRoundTrip() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at: url) }
    let s = Snapshot(updatedAt: Date(timeIntervalSince1970: 1_000_000), accounts: [
        AccountUsage(id: "/a", provider: .codex, label: "cdx1", limits: [Limit(name: "7d", percent: 50, resetsAt: nil, ring: .middle)]),
    ])
    try SnapshotStore.save(s, to: url)
    let back = SnapshotStore.load(from: url)
    #expect(back.updatedAt == s.updatedAt)
    #expect(back.accounts == s.accounts)
}

@Test func staleAfterFollowsRefreshInterval() {
    #expect(Snapshot(updatedAt: Date(), accounts: []).staleAfter == 600)
    #expect(Snapshot(updatedAt: Date(), accounts: [], refreshInterval: 120).staleAfter == 600)
    #expect(Snapshot(updatedAt: Date(), accounts: [], refreshInterval: 600).staleAfter == 1260)
}

@Test func shortCodexWindowName() throws {
    let json = #"{"rate_limit":{"primary_window":{"used_percent":1,"limit_window_seconds":1800}}}"#
    #expect(try UsageParser.parseCodex(Data(json.utf8)).limits.first?.name == "30m")
}
