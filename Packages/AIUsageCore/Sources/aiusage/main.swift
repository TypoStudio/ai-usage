import AIUsageCore
import AIUsageFetch
import Foundation

// `aiusage`      — 켜진 계정의 사용량을 앱과 같은 로직으로 조회해 JSON 으로 출력한다 (앱이 떠 있지 않아도 된다).
// `aiusage mcp`  — 같은 것을 MCP(stdio) 서버로. 도구 `get_usage` 하나, 선택 인자 `provider` (claude|codex).
// 앱 설정(라벨·순서·켜짐·실행 파일 경로)이 있으면 그대로 따르고, 없으면 `~/.claude-*`, `~/.codex-*` 를 탐지한다.

let version = "0.1.7"
/// 앱 설정 (라벨·순서·켜짐·실행 파일 경로)
func prefs() -> UserDefaults? { UserDefaults(suiteName: "com.typostudio.aiusage") }

struct Account: Codable {
    var id: String
    var provider: ProviderKind
    var label: String
    var enabled: Bool
}

/// 앱 설정의 계정 목록(라벨·순서·켜짐)에, 앱이 아직 모르는 새로 탐지된 디렉토리를 뒤에 붙인다.
func accounts() -> [Account] {
    let saved = (prefs()?.data(forKey: "accounts")).flatMap { try? JSONDecoder().decode([Account].self, from: $0) } ?? []
    let known = Set(saved.map(\.id))
    let discovered = AccountDiscovery.discover().filter { !known.contains($0.path) }.map {
        Account(id: $0.path, provider: $0.provider, label: AccountDiscovery.defaultLabel(provider: $0.provider, path: $0.path), enabled: true)
    }
    return (saved + discovered).filter(\.enabled)
}

func usage(for a: Account, versions v: AccountFetcher.Versions) async -> AccountUsage {
    var u = AccountUsage(id: a.id, provider: a.provider, label: a.label)
    switch await AccountFetcher.fetch(provider: a.provider, dir: a.id, versions: v) {
    case let .ok(p, email, _):
        u.email = email; u.plan = p.plan; u.warning = p.warning; u.workspaceID = p.workspaceID
        u.limits = p.limits; u.status = .ok; u.fetchedAt = Date()
    case let .expired(msg, email, _): u.email = email; u.status = .expired; u.error = msg
    case let .rateLimited(email): u.email = email; u.status = .error; u.error = "429"
    case let .failed(msg, email, _): u.email = email; u.status = .error; u.error = msg
    case .skipped: u.status = .error
    }
    return u
}

func fetchAll(provider: ProviderKind?) async -> Snapshot {
    let v = await AccountFetcher.versions(claudePath: prefs()?.string(forKey: "claudePath"), codexPath: prefs()?.string(forKey: "codexPath"),
                                          agyPath: prefs()?.string(forKey: "agyPath"))
    let targets = accounts().filter { provider == nil || $0.provider == provider }
    var results: [String: AccountUsage] = [:]
    await withTaskGroup(of: AccountUsage.self) { group in
        for a in targets { group.addTask { await usage(for: a, versions: v) } }
        for await u in group { results[u.id] = u }
    }
    return Snapshot(updatedAt: Date(), accounts: targets.compactMap { results[$0.id] })
}

func json(_ s: Snapshot) -> String {
    String(decoding: (try? SnapshotStore.encode(s)) ?? Data(), as: UTF8.self)
}

// MARK: MCP (stdio, 줄 단위 JSON-RPC 2.0)

func send(_ obj: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func runMCP() async {
    let tool: [String: Any] = [
        "name": "get_usage",
        "description": "Claude Code / Codex / Antigravity 계정별 사용량(세션·주간 한도 %, 리셋 시각)을 조회한다. AI Usage 앱이 떠 있지 않아도 된다.",
        "inputSchema": ["type": "object", "properties": ["provider": ["type": "string", "enum": ["claude", "codex", "antigravity"]]]],
    ]
    while let line = readLine() {
        guard let data = line.data(using: .utf8),
              let req = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
        let method = req["method"] as? String ?? ""
        guard let id = req["id"] else { continue }   // 알림(notifications/*)은 응답하지 않는다
        let params = req["params"] as? [String: Any] ?? [:]
        var result: [String: Any]
        switch method {
        case "initialize":
            result = ["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                      "capabilities": ["tools": [:]], "serverInfo": ["name": "aiusage", "version": version]]
        case "ping": result = [:]
        case "tools/list": result = ["tools": [tool]]
        case "tools/call":
            guard params["name"] as? String == "get_usage" else {
                send(["jsonrpc": "2.0", "id": id, "error": ["code": -32602, "message": "unknown tool"]]); continue
            }
            let args = params["arguments"] as? [String: Any] ?? [:]
            let provider = (args["provider"] as? String).flatMap(ProviderKind.init(rawValue:))
            result = ["content": [["type": "text", "text": json(await fetchAll(provider: provider))]]]
        default:
            send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "unknown method \(method)"]]); continue
        }
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case nil:
    print(json(await fetchAll(provider: nil)))
case "claude", "codex", "antigravity":
    print(json(await fetchAll(provider: ProviderKind(rawValue: args[0]))))
case "mcp":
    await runMCP()
case "--version", "-v":
    print(version)
default:
    print("""
    사용법: aiusage [claude|codex|antigravity]   사용량을 JSON 으로 출력
           aiusage mcp              MCP 서버(stdio)로 실행 — 도구 get_usage
    """)
    exit(args.first == "--help" || args.first == "-h" ? 0 : 2)
}
