import Foundation
import Testing
@testable import AIUsageCore

/// 임시 디렉토리에 만든 가짜 홈. 실제 홈에는 절대 실행하지 않는다.
private final class FixtureHome {
    let url: URL
    var path: String { url.standardizedFileURL.path }
    var setup: AuthenticationSetup { AuthenticationSetup(home: url) }

    init(suffix: String = "", baseURL: URL = FileManager.default.temporaryDirectory) throws {
        url = baseURL.appendingPathComponent("aiusage-auth-\(UUID().uuidString)\(suffix)")
        let real = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        precondition(url.lastPathComponent.hasPrefix("aiusage-auth-") && url.standardizedFileURL.path != real,
                     "fixture must not be the real home")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        // 읽기 전용으로 바꾼 디렉토리도 지울 수 있게
        if let e = FileManager.default.enumerator(atPath: path) {
            for case let rel as String in e { chmod("\(path)/\(rel)", 0o755) }
        }
        try? FileManager.default.removeItem(at: url)
    }

    func p(_ rel: String) -> String { "\(path)/\(rel)" }

    func write(_ rel: String, _ text: String) throws {
        try FileManager.default.createDirectory(atPath: (p(rel) as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: p(rel)))
    }

    func mkdir(_ rel: String) throws {
        try FileManager.default.createDirectory(atPath: p(rel), withIntermediateDirectories: true)
    }

    func link(_ rel: String, to dest: String) throws {
        try FileManager.default.createDirectory(atPath: (p(rel) as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: p(rel), withDestinationPath: dest)
    }

    func read(_ rel: String) -> String? { try? String(contentsOfFile: p(rel), encoding: .utf8) }
    func node(_ rel: String) -> Node { Node.at(p(rel)) }

    func boundSocket(_ rel: String) throws -> Int32 {
        try mkdir((rel as NSString).deletingLastPathComponent)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(p(rel).utf8) + [0]
        try #require(bytes.count <= MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard status == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            close(fd)
            throw error
        }
        return fd
    }

    func json(_ rel: String) -> [String: Any]? {
        guard let d = FileManager.default.contents(atPath: p(rel)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    /// 경로 → 종류·내용·링크 대상. "아무것도 바뀌지 않음" 비교용 (링크는 따라가지 않음)
    func snapshot() -> [String: String] {
        var out: [String: String] = [:]
        func walk(_ rel: String) {
            let full = rel.isEmpty ? path : p(rel)
            switch Node.at(full) {
            case .directory:
                out[rel] = "dir"
                for c in ((try? FileManager.default.contentsOfDirectory(atPath: full)) ?? []).sorted() {
                    walk(rel.isEmpty ? c : "\(rel)/\(c)")
                }
            case .file: out[rel] = "file:" + (read(rel) ?? "?")
            case .symlink(let d): out[rel] = "link:" + d
            default: out[rel] = "other"
            }
        }
        walk("")
        return out
    }

    /// 생성된 헬퍼를 `HOME=<fixture>` 의 깨끗한 zsh 에서 실행 (rc 파일 읽지 않음)
    func zsh(_ script: String) throws -> (status: Int32, out: String, err: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["-i", "HOME=\(path)", "ZDOTDIR=\(path)", "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                          "/bin/zsh", "-f", "-c", script]
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out; proc.standardError = err
        try proc.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (proc.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
    }
}

private let hasJQ = ["/opt/homebrew/bin/jq", "/usr/local/bin/jq", "/usr/bin/jq"].contains {
    FileManager.default.isExecutableFile(atPath: $0)
}

private func conflicts(_ body: () throws -> Void) -> [String] {
    do { try body() } catch AuthenticationSetupError.conflicts(let c) { return c } catch { return ["unexpected: \(error)"] }
    return []
}

// MARK: - Validation

@Test func rejectsUnsafeAndReservedNames() throws {
    let h = try FixtureHome()
    for bad in ["", "../x", "a/b", ".", "..", "-x", "_x", "UPPER", "a b", "a;rm", "$(x)", "shared", "sync", "1", "42",
                String(repeating: "a", count: 33), "é"] {
        #expect(throws: AuthenticationSetupError.invalidAccountName(bad)) {
            try h.setup.preview(provider: .claude, accounts: ["one", bad])
        }
    }
    #expect(throws: AuthenticationSetupError.duplicateAccount("one")) {
        try h.setup.preview(provider: .claude, accounts: ["one", "two", "one"])
    }
    #expect(throws: AuthenticationSetupError.noAccounts) { try h.setup.preview(provider: .codex, accounts: []) }
    #expect(throws: AuthenticationSetupError.unsupportedProvider(.antigravity)) {
        try h.setup.preview(provider: .antigravity, accounts: ["one"])
    }
    #expect(h.snapshot() == ["": "dir"])
}

@Test func previewIsReadOnly() throws {
    let h = try FixtureHome()
    try h.write(".claude/settings.json", #"{"a":1}"#)
    try h.write(".claude.json", #"{"oauthAccount":{"emailAddress":"a@x"},"mcpServers":{"m":{"command":"x"}}}"#)
    let before = h.snapshot()
    let plan = try h.setup.preview(provider: .claude, accounts: ["one", "two"])
    #expect(plan.accounts == ["one", "two"])
    #expect(!plan.summary.isEmpty)
    #expect(plan.warnings.contains { $0.contains("Quit every running Claude Code session") })
    #expect(h.snapshot() == before)
}

// MARK: - Fresh home

@Test func freshClaudeHomeSharesSettingsFromStart() throws {
    let h = try FixtureHome()
    let plan = try h.setup.preview(provider: .claude, accounts: ["one", "two", "team"])
    let result = try h.setup.apply(plan)

    #expect(h.node(".claude") == .symlink(h.p(".claude-one")))
    for a in ["one", "two", "team"] {
        #expect(h.node(".claude-\(a)") == .directory)
        #expect(h.node(".claude-\(a)/settings.json") == .symlink(h.p(".claude-shared/settings.json")))
        #expect(h.node(".claude-\(a)/projects") == .symlink(h.p(".claude-shared/projects")))
        #expect(h.node(".claude-\(a)/.claude.json") == .missing)  // MCP 목록이 없으니 만들지 않음
    }
    #expect(h.read(".claude-shared/settings.json") == "{}\n")
    #expect(h.node(".claude-shared/keybindings.json") == .missing)  // 형식 불확실한 선택 파일은 만들지 않음
    #expect(h.node(".claude-one/keybindings.json") == .missing)
    #expect(h.node(".claude-shared/mcp.json") == .missing)
    #expect(result.accountPaths == ["one", "two", "team"].map { h.p(".claude-\($0)") })
    #expect(result.loginCommands.count == 3)
    #expect(result.loginCommands[1] == "CLAUDE_CONFIG_DIR='\(h.p(".claude-two"))' claude   # then run /login")
    #expect(h.read(".zshrc")?.contains(#"source "$HOME/.claude-shared/claude-account.zsh""#) == true)
    #expect(!result.backupPath.isEmpty)
}

@Test func freshCodexHomeSharesConfigFromStart() throws {
    let h = try FixtureHome()
    let result = try h.setup.apply(h.setup.preview(provider: .codex, accounts: ["one", "personal"]))
    #expect(h.node(".codex") == .symlink(h.p(".codex-one")))
    #expect(h.read(".codex-shared/config.toml") == "")
    for a in ["one", "personal"] {
        #expect(h.node(".codex-\(a)/config.toml") == .symlink(h.p(".codex-shared/config.toml")))
        #expect(h.node(".codex-\(a)/auth.json") == .missing)
    }
    #expect(result.loginCommands == ["one", "personal"].map { "CODEX_HOME='\(h.p(".codex-\($0)"))' codex login" })
}

// MARK: - Migration

@Test func migratesDefaultClaudeDirectoryWithBackup() throws {
    let h = try FixtureHome()
    try h.write(".claude/settings.json", #"{"theme":"dark"}"#)
    try h.write(".claude/projects/p/memory.md", "remember")
    try h.write(".claude/.credentials.json", "SECRET")
    try h.write(".claude/sessions/s1", "session")
    let global = #"{"oauthAccount":{"emailAddress":"me@x"},"mcpServers":{"fs":{"command":"npx"}}}"#
    try h.write(".claude.json", global)

    let plan = try h.setup.preview(provider: .claude, accounts: ["one", "two"])
    #expect(plan.warnings.contains { $0.contains("keychain") && $0.contains("/login") })
    let result = try h.setup.apply(plan)

    // 원래 폴더 → .claude-one, 링크로 교체
    #expect(h.node(".claude") == .symlink(h.p(".claude-one")))
    #expect(h.node(".claude-one") == .directory)
    #expect(h.read(".claude-shared/settings.json") == #"{"theme":"dark"}"#)
    #expect(h.node(".claude-one/settings.json") == .symlink(h.p(".claude-shared/settings.json")))
    #expect(h.read(".claude-two/projects/p/memory.md") == "remember")
    // 계정별 항목은 이동만, 공유 안 함
    #expect(h.node(".claude-one/.credentials.json") == .file)
    #expect(h.node(".claude-one/sessions") == .directory)
    #expect(h.node(".claude-two/sessions") == .missing)
    #expect(h.node(".claude-two/.credentials.json") == .missing)
    // ~/.claude.json 은 복사만, 원본 유지
    #expect(h.read(".claude.json") == global)
    #expect(h.read(".claude-one/.claude.json") == global)
    // MCP 목록 추출, 새 계정엔 로그인 정보 없이 mcpServers 만
    #expect((h.json(".claude-shared/mcp.json")?["mcpServers"] as? [String: Any])?.keys.sorted() == ["fs"])
    let two = try #require(h.json(".claude-two/.claude.json"))
    #expect(two.keys.sorted() == ["mcpServers"])
    // 키체인은 옮기지 않으므로 one 도 다시 로그인
    #expect(result.loginCommands.count == 2)
    #expect(result.loginCommands[0].contains(".claude-one"))

    // 백업: 원래 데이터 + 매니페스트, 소유자 전용 권한
    let b = result.backupPath
    #expect(b.hasPrefix(h.p("claude-setup-backup-")))
    #expect(try String(contentsOfFile: "\(b)/.claude/settings.json", encoding: .utf8) == #"{"theme":"dark"}"#)
    #expect(try String(contentsOfFile: "\(b)/.claude/.credentials.json", encoding: .utf8) == "SECRET")
    #expect(try String(contentsOfFile: "\(b)/.claude.json", encoding: .utf8) == global)
    #expect(FileManager.default.fileExists(atPath: "\(b)/backup-manifest.txt"))
    let mode = try FileManager.default.attributesOfItem(atPath: b)[.posixPermissions] as? Int
    #expect(mode == 0o700)
}

@Test func migratesDefaultCodexDirectory() throws {
    let h = try FixtureHome()
    try h.write(".codex/auth.json", #"{"tokens":{}}"#)
    try h.write(".codex/config.toml", "model = \"x\"\n")
    try h.write(".codex/sessions/a.jsonl", "s")
    try h.write(".claude-shared/response-format.md", "rules")
    let result = try h.setup.apply(h.setup.preview(provider: .codex, accounts: ["one", "two"]))
    #expect(h.node(".codex") == .symlink(h.p(".codex-one")))
    #expect(h.node(".codex-one/auth.json") == .file)
    #expect(h.node(".codex-two/auth.json") == .missing)
    #expect(h.read(".codex-shared/config.toml") == "model = \"x\"\n")
    #expect(h.node(".codex-two/config.toml") == .symlink(h.p(".codex-shared/config.toml")))
    #expect(h.node(".codex-two/AGENTS.md") == .symlink(h.p(".claude-shared/response-format.md")))
    #expect(result.loginCommands == ["CODEX_HOME='\(h.p(".codex-two"))' codex login"])
}

@Test(arguments: [false, true]) func codexBackupSkipsLiveIPCFiles(activeLink: Bool) throws {
    // Unix socket paths must fit sun_path, so use a short fixture path.
    let h = try FixtureHome(baseURL: URL(fileURLWithPath: "/tmp"))
    let account = activeLink ? ".codex-one" : ".codex"
    let auth = #"{"tokens":{"id_token":"fixture","refresh_token":"private"}}"#
    try h.write("\(account)/auth.json", auth)
    try #require(chmod(h.p("\(account)/auth.json"), 0o600) == 0)
    try h.write("\(account)/config.toml", "model = \"fixture\"\n")
    try h.write("\(account)/sessions/ipc.sock", "A regular file with a socket-like name")
    try h.link("\(account)/session-link", to: "sessions/ipc.sock")
    if activeLink { try h.link(".codex", to: h.p(account)) }
    let fd = try h.boundSocket("\(account)/ipc/ipc.sock")
    defer { close(fd) }
    try #require(mkfifo(h.p("\(account)/ipc/events"), 0o600) == 0)

    let plan = try h.setup.preview(provider: .codex, accounts: ["one", "two", "three", "personal"])
    let result = try h.setup.apply(plan)
    let backup = URL(fileURLWithPath: result.backupPath).appendingPathComponent(account)
    #expect(try String(contentsOf: backup.appendingPathComponent("auth.json"), encoding: .utf8) == auth)
    #expect(try FileManager.default.attributesOfItem(atPath: backup.appendingPathComponent("auth.json").path)[.posixPermissions] as? Int == 0o600)
    #expect(try String(contentsOf: backup.appendingPathComponent("config.toml"), encoding: .utf8) == "model = \"fixture\"\n")
    #expect(try String(contentsOf: backup.appendingPathComponent("sessions/ipc.sock"), encoding: .utf8) == "A regular file with a socket-like name")
    #expect(Node.at(backup.appendingPathComponent("session-link").path) == .symlink("sessions/ipc.sock"))
    #expect(Node.at(backup.appendingPathComponent("ipc/ipc.sock").path) == .missing)
    #expect(Node.at(backup.appendingPathComponent("ipc/events").path) == .missing)
    let manifest = try String(contentsOfFile: "\(result.backupPath)/backup-manifest.txt", encoding: .utf8)
    #expect(manifest.contains("\(h.p("\(account)/ipc/ipc.sock"))\tskipped-socket\t"))
    #expect(manifest.contains("\(h.p("\(account)/ipc/events"))\tskipped-fifo\t"))
    #expect(h.node(".codex") == .symlink(h.p(".codex-one")))
    #expect(h.read(".codex-one/auth.json") == auth)
    #expect(h.node(".codex-two/auth.json") == .missing)
    #expect(try FileManager.default.attributesOfItem(atPath: h.p(".codex-one/ipc/ipc.sock"))[.type] as? FileAttributeType == .typeSocket)
    var pipeInfo = stat()
    #expect(lstat(h.p(".codex-one/ipc/events"), &pipeInfo) == 0)
    #expect(pipeInfo.st_mode & S_IFMT == S_IFIFO)
}

@Test func unreadableRegularFileStillStopsBackup() throws {
    let h = try FixtureHome()
    try h.write(".codex/auth.json", "PRIVATE")
    try h.write(".codex/config.toml", "model = \"fixture\"\n")
    try h.write(".codex/unreadable", "KEEP")
    let plan = try h.setup.preview(provider: .codex, accounts: ["one", "two"])
    try #require(chmod(h.p(".codex/unreadable"), 0) == 0)
    defer { chmod(h.p(".codex/unreadable"), 0o600) }
    do {
        _ = try h.setup.apply(plan)
        Issue.record("Expected a backup error for the unreadable regular file")
    } catch AuthenticationSetupError.backupFailed {
        #expect(h.node(".codex") == .directory)
        #expect(h.node(".codex-one") == .missing)
        #expect(h.read(".codex/auth.json") == "PRIVATE")
        #expect(h.read(".codex/config.toml") == "model = \"fixture\"\n")
    }
}

@Test func backsUpTargetDataOfSymlinkedActiveAccount() throws {
    let h = try FixtureHome()
    try h.write(".claude-one/settings.json", "ORIGINAL")
    try h.write(".claude-one/.claude.json", #"{"oauthAccount":{"emailAddress":"a@x"}}"#)
    try h.link(".claude", to: h.p(".claude-one"))
    let result = try h.setup.apply(h.setup.preview(provider: .claude, accounts: ["one", "two"]))
    #expect(h.node(".claude-one/settings.json") == .symlink(h.p(".claude-shared/settings.json")))
    // 링크만이 아니라 대상 계정의 실제 데이터가 백업됨
    #expect(try String(contentsOfFile: "\(result.backupPath)/.claude-one/settings.json", encoding: .utf8) == "ORIGINAL")
    let manifest = try String(contentsOfFile: "\(result.backupPath)/backup-manifest.txt", encoding: .utf8)
    #expect(manifest.contains("\(h.p(".claude"))\tsymlink\t\(h.p(".claude-one"))"))
    #expect(result.loginCommands == ["CLAUDE_CONFIG_DIR='\(h.p(".claude-two"))' claude   # then run /login"])
}

// MARK: - Idempotence

@Test func secondRunChangesNothing() throws {
    let h = try FixtureHome()
    try h.write(".claude/settings.json", "{}")
    try h.write(".claude.json", #"{"mcpServers":{"fs":{"command":"npx"}}}"#)
    _ = try h.setup.apply(h.setup.preview(provider: .claude, accounts: ["one", "two"]))
    let after = h.snapshot()

    let again = try h.setup.preview(provider: .claude, accounts: ["one", "two"])
    #expect(again.summary.contains("Already set up; nothing to change."))
    let r = try h.setup.apply(again)
    #expect(r.backupPath == "")
    #expect(h.snapshot() == after)
    #expect(h.read(".zshrc")?.components(separatedBy: "claude-account.zsh").count == 3)  // 한 줄에 두 번 = 1줄
    // mcpServers 만 있는 .claude.json 은 로그인 전으로 본다
    #expect(r.loginCommands.count == 2)
}

@Test func existingZshrcSourceLineIsNotDuplicated() throws {
    let h = try FixtureHome()
    try h.write(".zshrc", "export A=1\nsource ~/.claude-shared/claude-account.zsh\n")
    _ = try h.setup.apply(h.setup.preview(provider: .claude, accounts: ["one"]))
    #expect(h.read(".zshrc") == "export A=1\nsource ~/.claude-shared/claude-account.zsh\n")
}

@Test func appendsToZshrcWithoutTrailingNewline() throws {
    let h = try FixtureHome()
    try h.write(".zshrc", "export A=1")
    _ = try h.setup.apply(h.setup.preview(provider: .codex, accounts: ["one"]))
    let text = try #require(h.read(".zshrc"))
    #expect(text.hasPrefix("export A=1\n\n# AI Usage: Codex account helper\n"))
}

@Test func symlinkedZshrcIsNotEdited() throws {
    let h = try FixtureHome()
    try h.write("dotfiles/zshrc", "x\n")
    try h.link(".zshrc", to: h.p("dotfiles/zshrc"))
    let plan = try h.setup.preview(provider: .claude, accounts: ["one"])
    #expect(plan.warnings.contains { $0.contains("~/.zshrc is a symlink") })
    _ = try h.setup.apply(plan)
    #expect(h.read("dotfiles/zshrc") == "x\n")
}

@Test func foreignHelperIsKeptGeneratedHelperIsRegenerated() throws {
    let h = try FixtureHome()
    try h.write(".claude-shared/claude-account.zsh", "# my own helper\n")
    let plan = try h.setup.preview(provider: .claude, accounts: ["one"])
    #expect(plan.warnings.contains { $0.contains("not created by AI Usage") })
    _ = try h.setup.apply(plan)
    #expect(h.read(".claude-shared/claude-account.zsh") == "# my own helper\n")

    let g = try FixtureHome()
    _ = try g.setup.apply(g.setup.preview(provider: .claude, accounts: ["one"]))
    _ = try g.setup.apply(g.setup.preview(provider: .claude, accounts: ["one", "two"]))
    #expect(g.read(".claude-shared/claude-account.zsh")?.contains("CLAUDE_ACCOUNTS=(one two)") == true)
}

// MARK: - Conflicts (refused, nothing changed)

@Test func refusesWhenMigrationTargetExists() throws {
    let h = try FixtureHome()
    try h.write(".claude/settings.json", "A")
    try h.write(".claude-one/settings.json", "B")
    let before = h.snapshot()
    #expect(conflicts { _ = try h.setup.preview(provider: .claude, accounts: ["one", "two"]) }.count == 1)
    #expect(h.snapshot() == before)
}

@Test func refusesTwoCopiesOfSharedItem() throws {
    let h = try FixtureHome()
    try h.write(".claude-shared/settings.json", "SHARED")
    try h.write(".claude-two/settings.json", "LOCAL")
    try h.write(".claude-one/CLAUDE.md", "one")
    try h.write(".claude-three/CLAUDE.md", "three")
    let before = h.snapshot()
    let c = conflicts { _ = try h.setup.preview(provider: .claude, accounts: ["one", "two", "three"]) }
    #expect(c.contains { $0.contains("settings.json") && $0.contains("both exist") })
    #expect(c.contains { $0.contains("CLAUDE.md exists in several accounts") })
    #expect(h.snapshot() == before)
}

@Test func refusesSymlinkedLoginFilesAndAccountDirs() throws {
    let h = try FixtureHome()
    try h.write(".claude-one/.claude.json", "{}")
    try h.link(".claude-two/.claude.json", to: h.p(".claude-one/.claude.json"))
    try h.link(".claude-three", to: h.p(".claude-one"))
    let c = conflicts { _ = try h.setup.preview(provider: .claude, accounts: ["one", "two", "three"]) }
    #expect(c.contains { $0.contains(".claude-two/.claude.json") && $0.contains("never be shared") })
    #expect(c.contains { $0.contains(".claude-three is a link") })

    let x = try FixtureHome()
    try x.write(".codex-one/auth.json", "{}")
    try x.link(".codex-two/auth.json", to: x.p(".codex-one/auth.json"))
    #expect(!conflicts { _ = try x.setup.preview(provider: .codex, accounts: ["one", "two"]) }.isEmpty)
}

@Test func refusesActiveLinkToNonAccountPath() throws {
    let h = try FixtureHome()
    try h.mkdir("dotfiles/claude")
    try h.link(".claude", to: h.p("dotfiles/claude"))
    #expect(conflicts { _ = try h.setup.preview(provider: .claude, accounts: ["one"]) }.count == 1)
    let d = try FixtureHome()
    try d.link(".claude", to: d.p(".claude-gone"))
    #expect(conflicts { _ = try d.setup.preview(provider: .claude, accounts: ["one"]) }.count == 1)
}

@Test func refusesSharedDirectoryOverlappingAccounts() throws {
    for target in [".claude-one", ".claude-one/sub", ".claude", ""] {
        let h = try FixtureHome()
        try h.mkdir(".claude-one/sub")
        try h.mkdir(".claude")
        try h.link(".claude-shared", to: target.isEmpty ? h.path : h.p(target))
        let before = h.snapshot()
        let c = conflicts { _ = try h.setup.preview(provider: .claude, accounts: ["one", "two"]) }
        #expect(c.contains { $0.contains(".claude-shared resolves to") }, "target \(target)")
        #expect(h.snapshot() == before)
    }
    // 홈 밖의 별도 디렉토리를 가리키는 공통 링크는 허용
    let ok = try FixtureHome()
    try ok.mkdir("dotfiles/claude-shared")
    try ok.link(".claude-shared", to: ok.p("dotfiles/claude-shared"))
    _ = try ok.setup.apply(ok.setup.preview(provider: .claude, accounts: ["one"]))
    #expect(ok.read("dotfiles/claude-shared/settings.json") == "{}\n")
}

// MARK: - Preserving links and the active account

@Test func activeAccountOutsideRequestedNamesIsPreserved() throws {
    let h = try FixtureHome()
    try h.write(".claude-work/.claude.json", #"{"oauthAccount":{"emailAddress":"w@x"}}"#)
    try h.link(".claude", to: h.p(".claude-work"))
    let plan = try h.setup.preview(provider: .claude, accounts: ["one"])
    #expect(plan.accounts == ["one", "work"])
    #expect(plan.warnings.contains { $0.contains("\"work\"") })
    let r = try h.setup.apply(plan)
    #expect(h.node(".claude") == .symlink(h.p(".claude-work")))
    #expect(r.loginCommands.count == 1 && r.loginCommands[0].contains(".claude-one"))
}

@Test func relativeActiveLinkIsKept() throws {
    let h = try FixtureHome()
    try h.mkdir(".claude-two")
    try h.link(".claude", to: ".claude-two")
    let plan = try h.setup.preview(provider: .claude, accounts: ["one", "two"])
    _ = try h.setup.apply(plan)
    #expect(h.node(".claude") == .symlink(".claude-two"))
}

@Test func foreignLinksAreLeftUntouched() throws {
    let h = try FixtureHome()
    try h.mkdir("dotfiles/skills")
    try h.link(".claude-one/skills", to: h.p("dotfiles/skills"))
    try h.mkdir(".claude-two")
    let plan = try h.setup.preview(provider: .claude, accounts: ["one", "two"])
    #expect(plan.warnings.contains { $0.contains("Kept existing link") })
    _ = try h.setup.apply(plan)
    #expect(h.node(".claude-one/skills") == .symlink(h.p("dotfiles/skills")))
    #expect(h.node(".claude-two/skills") == .missing)
    #expect(h.node(".claude-shared/skills") == .missing)
}

@Test func existingCorrectLinksAreNotRecreated() throws {
    let h = try FixtureHome()
    try h.write(".claude-shared/settings.json", "S")
    try h.link(".claude-one/settings.json", to: "../.claude-shared/settings.json")  // 상대 링크도 인정
    let plan = try h.setup.preview(provider: .claude, accounts: ["one"])
    #expect(!plan.summary.contains { $0.contains("Link ~/.claude-one/settings.json") })
    _ = try h.setup.apply(plan)
    #expect(h.node(".claude-one/settings.json") == .symlink("../.claude-shared/settings.json"))
}

// MARK: - Auth isolation

@Test func loginFilesAreNeverShared() throws {
    let h = try FixtureHome()
    try h.write(".claude/.credentials.json", "SECRET")
    try h.write(".claude.json", #"{"oauthAccount":{"emailAddress":"a@x"},"mcpServers":{"m":{}}}"#)
    _ = try h.setup.apply(h.setup.preview(provider: .claude, accounts: ["one", "two", "three"]))
    for a in ["one", "two", "three"] {
        for f in [".claude.json", ".credentials.json", "sessions", "cache"] {
            if case .symlink = h.node(".claude-\(a)/\(f)") { Issue.record("\(a)/\(f) is a symlink") }
        }
        #expect(h.json(".claude-\(a)/.claude.json")?["oauthAccount"] == nil || a == "one")
    }
    for f in [".claude.json", ".credentials.json"] { #expect(h.node(".claude-shared/\(f)") == .missing) }
    #expect(h.node(".claude-two/.credentials.json") == .missing)
}

// MARK: - Revalidation and rollback

@Test func applyRefusesWhenStateChangedAfterPreview() throws {
    let h = try FixtureHome()
    let plan = try h.setup.preview(provider: .claude, accounts: ["one", "two"])
    try h.write(".claude-two/settings.json", "NEW")
    let before = h.snapshot()
    #expect(throws: AuthenticationSetupError.planOutdated) { try h.setup.apply(plan) }
    #expect(h.snapshot() == before)
    let other = try FixtureHome()
    #expect(throws: AuthenticationSetupError.planOutdated) { try other.setup.apply(plan) }
}

@Test func failedApplyRollsBackCompletedSteps() throws {
    let h = try FixtureHome()
    try h.mkdir(".claude-shared")
    try h.write(".claude-one/settings.json", "MINE")
    let plan = try h.setup.preview(provider: .claude, accounts: ["one", "two"])
    chmod(h.p(".claude-shared"), 0o555)  // 공통 디렉토리로 옮기기가 실패하도록
    defer { chmod(h.p(".claude-shared"), 0o755) }
    do {
        _ = try h.setup.apply(plan)
        Issue.record("expected failure")
    } catch AuthenticationSetupError.applyFailed(_, _, let backup, let rollbackFailures) {
        #expect(rollbackFailures.isEmpty)
        #expect(FileManager.default.fileExists(atPath: "\(backup)/.claude-one/settings.json"))
    }
    #expect(h.read(".claude-one/settings.json") == "MINE")
    #expect(h.node(".claude-two") == .missing)
    #expect(h.node(".claude") == .missing)
}

// MARK: - Shell helper

@Test func helperAliasesAndShortcutsAreCollisionFree() {
    let s = HelperScript(layout: Layout(.claude)!, accounts: ["one", "two", "team", "personal", "tango"])
    let text = s.text
    #expect(text.contains("one|1) print -r -- one ;;"))
    #expect(text.contains("personal|p) print -r -- personal ;;"))
    #expect(text.contains("    team) print -r -- team ;;"))  // team/tango 는 t 가 겹쳐 단축키 없음
    let aliases = text.split(separator: "\n").filter { $0.hasPrefix("alias ") }
        .map { String($0.dropFirst(6).prefix { $0 != "=" }) }
    #expect(aliases == ["cld1", "cld2", "cldteam", "cldpersonal", "cldtango"])
    #expect(Set(aliases).count == aliases.count)
    #expect(HelperScript(layout: Layout(.codex)!, accounts: ["one", "personal"]).text.contains("alias cdxpersonal='CODEX_HOME=\"$HOME/.codex-personal\" codex'"))
}

@Test func generatedHelpersAreValidZsh() throws {
    let h = try FixtureHome()
    _ = try h.setup.apply(h.setup.preview(provider: .claude, accounts: ["one", "two", "team"]))
    _ = try h.setup.apply(h.setup.preview(provider: .codex, accounts: ["one", "personal"]))
    for f in [".claude-shared/claude-account.zsh", ".codex-shared/codex-account.zsh", ".zshrc"] {
        let r = try h.zsh("zsh -n \"$HOME/\(f)\"")
        #expect(r.status == 0, "\(f): \(r.err)")
    }
}

@Test(.enabled(if: hasJQ)) func claudeHelperSwitchesAndSyncsInFixtureHome() throws {
    let h = try FixtureHome()
    try h.write(".claude.json", #"{"oauthAccount":{"emailAddress":"one@x"},"mcpServers":{"fs":{"command":"npx"}}}"#)
    try h.mkdir(".claude")
    _ = try h.setup.apply(h.setup.preview(provider: .claude, accounts: ["one", "two", "team"]))
    try h.mkdir(".claude-team")  // 이미 있음 — 로그인 전 계정
    try FileManager.default.removeItem(atPath: h.p(".claude-team/.claude.json"))
    try h.write(".claude-shared/mcp.json", #"{"mcpServers":{"fs":{"command":"npx"},"gh":{"command":"gh"}}}"#)

    let r = try h.zsh(#"""
    source "$HOME/.zshrc"
    print -r -- "start=$CLAUDE_CONFIG_DIR"
    claude-account 2 || exit 9
    print -r -- "after=$(readlink "$HOME/.claude") env=$CLAUDE_CONFIG_DIR"
    claude-account one >/dev/null || exit 8
    claude-account
    """#)
    #expect(r.status == 0, "\(r.err)")
    #expect(r.out.contains("start=\(h.p(".claude-one"))"))
    #expect(r.out.contains("after=\(h.p(".claude-two")) env=\(h.p(".claude-two"))"))
    #expect(r.out.contains("* one  one@x"))
    #expect(r.out.contains("  two  -"))
    #expect(h.node(".claude") == .symlink(h.p(".claude-one")))
    // 모든 계정에 MCP 배포 — 로그인 정보는 그대로, 없던 파일은 mcpServers 만
    #expect((h.json(".claude-one/.claude.json")?["oauthAccount"] as? [String: Any])?["emailAddress"] as? String == "one@x")
    for a in ["one", "two", "team"] {
        #expect((h.json(".claude-\(a)/.claude.json")?["mcpServers"] as? [String: Any])?.keys.sorted() == ["fs", "gh"])
    }
    #expect(h.json(".claude-team/.claude.json")?.keys.sorted() == ["mcpServers"])
    #expect(h.read(".claude.json")?.contains("\"gh\"") == false)  // 기본 위치 파일은 건드리지 않음

    let u = try h.zsh(#"source "$HOME/.claude-shared/claude-account.zsh"; claude-account nope"#)
    #expect(u.status != 0 && u.err.contains("usage: claude-account"))
}

@Test(.enabled(if: hasJQ)) func mcpSyncRefusesUnsafeTargetsAndReportsFailure() throws {
    let h = try FixtureHome()
    _ = try h.setup.apply(h.setup.preview(provider: .claude, accounts: ["one", "two", "three"]))
    try h.write(".claude-shared/mcp.json", #"{"mcpServers":{"fs":{}}}"#)
    try h.write("elsewhere.json", #"{"oauthAccount":{"emailAddress":"x@x"}}"#)
    try h.link(".claude-one/.claude.json", to: h.p("elsewhere.json"))
    try h.write(".claude-two/.claude.json", "[1,2]")
    try h.write(".claude-three/.claude.json", "{\"a\":1}\n{\"b\":2}")

    let r = try h.zsh(#"source "$HOME/.claude-shared/claude-account.zsh"; claude-account sync"#)
    #expect(r.status != 0)
    #expect(r.err.contains("skipped one"))
    #expect(h.read("elsewhere.json") == #"{"oauthAccount":{"emailAddress":"x@x"}}"#)
    #expect(h.read(".claude-two/.claude.json") == "[1,2]")
    #expect(h.read(".claude-three/.claude.json") == "{\"a\":1}\n{\"b\":2}")

    // 전환은 되지만 sync 실패는 종료 코드로 알린다
    let s = try h.zsh(#"source "$HOME/.claude-shared/claude-account.zsh"; claude-account 2"#)
    #expect(s.status != 0)
    #expect(s.err.contains("switched, but MCP sync failed"))
    #expect(h.node(".claude") == .symlink(h.p(".claude-two")))

    // ~/.claude 가 실제 폴더면 전환 거절
    try FileManager.default.removeItem(atPath: h.p(".claude"))
    try h.mkdir(".claude")
    let x = try h.zsh(#"source "$HOME/.claude-shared/claude-account.zsh"; claude-account one"#)
    #expect(x.status != 0 && x.err.contains("refusing"))
    #expect(h.node(".claude") == .directory)
}

@Test(.enabled(if: hasJQ)) func codexHelperReadsEmailAndFlagsUnlinkedConfig() throws {
    let h = try FixtureHome()
    _ = try h.setup.apply(h.setup.preview(provider: .codex, accounts: ["one", "two"]))
    // header.payload.sig — payload {"email":"c@x"} (base64url, 패딩 없음)
    let payload = Data(#"{"email":"c@x"}"#.utf8).base64EncodedString()
        .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    try h.write(".codex-one/auth.json", #"{"tokens":{"id_token":"h.\#(payload).s"}}"#)
    try FileManager.default.removeItem(atPath: h.p(".codex-two/config.toml"))
    try h.write(".codex-two/config.toml", "rewritten")
    let r = try h.zsh(#"""
    source "$HOME/.zshrc"
    codex-account
    codex-account 2 >/dev/null && print -r -- "home=$CODEX_HOME"
    """#)
    #expect(r.status == 0, "\(r.err)")
    #expect(r.out.contains("* one  c@x"))
    #expect(r.out.contains("  two  -\n    ! config.toml is not linked"))
    #expect(r.out.contains("home=\(h.p(".codex-two"))"))
}

@Test func freshMCPOnlyConfigStillNeedsLoginOnRerun() throws {
    let h = try FixtureHome()
    try h.write(".claude-shared/mcp.json", #"{"mcpServers":{"fs":{"command":"npx"}}}"#)
    let first = try h.setup.apply(h.setup.preview(provider: .claude, accounts: ["one", "two"]))
    #expect(h.json(".claude-one/.claude.json")?.keys.sorted() == ["mcpServers"])
    #expect(h.json(".claude-two/.claude.json")?.keys.sorted() == ["mcpServers"])
    #expect(first.loginCommands.count == 2)

    let again = try h.setup.preview(provider: .claude, accounts: ["one", "two"])
    #expect(again.summary.contains("Already set up; nothing to change."))
    let second = try h.setup.apply(again)
    #expect(second.backupPath == "")
    #expect(second.loginCommands == first.loginCommands)

    // 로그인 후(oauthAccount 생김)에는 빠진다
    try h.write(".claude-two/.claude.json", #"{"oauthAccount":{"emailAddress":"t@x"},"mcpServers":{}}"#)
    #expect(try h.setup.apply(h.setup.preview(provider: .claude, accounts: ["one", "two"])).loginCommands
        == [first.loginCommands[0]])
}

@Test(.enabled(if: hasJQ)) func homeWithSpacesAndApostropheIsQuoted() throws {
    let h = try FixtureHome(suffix: " it's home")
    #expect(h.path.contains(" it's home"))
    try h.write(".claude-shared/mcp.json", #"{"mcpServers":{"fs":{}}}"#)
    let claude = try h.setup.apply(h.setup.preview(provider: .claude, accounts: ["one", "two"]))
    let codex = try h.setup.apply(h.setup.preview(provider: .codex, accounts: ["one"]))

    // 로그인 명령을 셸이 그대로 해석하면 정확한 경로가 나와야 한다 (claude/codex 대신 printenv)
    for (cmd, real, env) in [(claude.loginCommands[1], " claude ", "CLAUDE_CONFIG_DIR"),
                             (codex.loginCommands[0], " codex login", "CODEX_HOME")] {
        let probe = cmd.replacingOccurrences(of: real, with: " printenv \(env) ")
        let r = try h.zsh(probe)
        #expect(r.status == 0, "\(r.err)")
        #expect(r.out == (env == "CODEX_HOME" ? h.p(".codex-one") : h.p(".claude-two")) + "\n")
    }

    let r = try h.zsh(#"""
    source "$HOME/.zshrc"
    claude-account 2 >/dev/null || exit 9
    print -r -- "claude=$CLAUDE_CONFIG_DIR"
    codex-account 1 >/dev/null || exit 8
    print -r -- "codex=$CODEX_HOME"
    claude-account
    """#)
    #expect(r.status == 0, "\(r.err)")
    #expect(r.out.contains("claude=\(h.p(".claude-two"))\n"))
    #expect(r.out.contains("codex=\(h.p(".codex-one"))\n"))
    #expect(r.out.contains("* two  -"))
    #expect(h.node(".claude") == .symlink(h.p(".claude-two")))
    #expect((h.json(".claude-one/.claude.json")?["mcpServers"] as? [String: Any])?.keys.sorted() == ["fs"])
}

// MARK: - Partial writes (RLIMIT_FSIZE 와 같은 동작을 테스트 프로세스 전역 설정 없이 재현)

/// 경로에 `name` 이 들어간 파일만 `cap` 바이트까지 쓰게 하고, 넘으면 EFBIG — 커널 파일 크기 제한과 같은 부분 쓰기
private func sizeCap(_ cap: Int, on name: String) -> FileIO {
    var io = FileIO()
    io.write = { fd, buf, n in
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &path) == 0, String(cString: path).contains(name) else { return Darwin.write(fd, buf, n) }
        let allowed = cap - Int(lseek(fd, 0, SEEK_CUR))
        if allowed <= 0 { errno = EFBIG; return -1 }
        return Darwin.write(fd, buf, min(n, allowed))
    }
    return io
}

private func applyFailure(_ body: () throws -> Void) -> (reason: String, rollback: [String], message: String)? {
    do { try body() } catch let e as AuthenticationSetupError {
        if case let .applyFailed(_, reason, _, rollback) = e { return (reason, rollback, e.localizedDescription) }
    } catch {}
    return nil
}

private func withoutBackups(_ snap: [String: String]) -> [String: String] {
    snap.filter { !$0.key.hasPrefix("claude-setup-backup-") && !$0.key.hasPrefix("codex-setup-backup-") }
}

@Test func failedZshrcAppendLeavesItByteIdentical() throws {
    let h = try FixtureHome()
    let original = String(repeating: "# line\n", count: 568) + "export X=1"  // 3986 bytes, 끝 줄바꿈 없음
    try h.write(".zshrc", original)
    let before = h.snapshot()
    let plan = try h.setup.preview(provider: .claude, accounts: ["one", "two"])
    let f = try #require(applyFailure { _ = try h.setup.apply(plan, io: sizeCap(4096, on: ".zshrc")) })
    #expect(f.rollback.isEmpty)
    #expect(f.reason.contains("too large"))
    #expect(f.message.contains("All changes were rolled back"))
    #expect(FileManager.default.contents(atPath: h.p(".zshrc")) == Data(original.utf8))
    #expect(withoutBackups(h.snapshot()) == before)
}

@Test func failedHelperWriteRemovesPartialFile() throws {
    let h = try FixtureHome()
    let before = h.snapshot()
    let plan = try h.setup.preview(provider: .codex, accounts: ["one"])
    let f = try #require(applyFailure { _ = try h.setup.apply(plan, io: sizeCap(100, on: "codex-account.zsh")) })
    #expect(f.rollback.isEmpty)
    #expect(h.node(".codex-shared/codex-account.zsh") == .missing)
    #expect(withoutBackups(h.snapshot()) == before)
}

@Test func failedHelperRegenerationKeepsOldHelper() throws {
    let h = try FixtureHome()
    _ = try h.setup.apply(h.setup.preview(provider: .claude, accounts: ["one"]))
    let old = try #require(h.read(".claude-shared/claude-account.zsh"))
    let before = h.snapshot()
    let plan = try h.setup.preview(provider: .claude, accounts: ["one", "two"])
    let f = try #require(applyFailure { _ = try h.setup.apply(plan, io: sizeCap(100, on: "claude-account.zsh")) })
    #expect(f.rollback.isEmpty)
    #expect(h.read(".claude-shared/claude-account.zsh") == old)
    #expect(withoutBackups(h.snapshot()) == withoutBackups(before))  // 임시 파일도 남지 않음
}

@Test func failedPermissionChangeRemovesNewFile() throws {
    let h = try FixtureHome()
    var io = FileIO()
    io.fchmod = { _, _ in errno = EPERM; return -1 }
    #expect(throws: OpFailure.self) { _ = try AuthenticationSetup.perform(.write(h.p("new.json"), Data("{}".utf8), 0o600), io: io) }
    #expect(h.node("new.json") == .missing)
}

@Test func existingTargetIsNeverDeletedOnCreateFailure() throws {
    let h = try FixtureHome()
    try h.write("keep", "MINE")
    try h.write("src.json", "{}")
    #expect(throws: (any Error).self) { _ = try AuthenticationSetup.perform(.write(h.p("keep"), Data("x".utf8), 0o600)) }
    #expect(throws: (any Error).self) { _ = try AuthenticationSetup.perform(.copy(h.p("src.json"), h.p("keep"))) }
    #expect(h.read("keep") == "MINE")
    // 링크는 따라가 쓰지 않는다
    try h.link("dangling", to: h.p("target-not-created"))
    #expect(throws: (any Error).self) { _ = try AuthenticationSetup.perform(.write(h.p("dangling"), Data("x".utf8), 0o600)) }
    #expect(h.node("target-not-created") == .missing)
}

@Test func cleanupFailureIsReportedNotHidden() throws {
    let h = try FixtureHome()
    try h.write(".zshrc", String(repeating: "x", count: 4000))
    var io = sizeCap(4096, on: ".zshrc")
    io.ftruncate = { _, _ in errno = EIO; return -1 }
    let plan = try h.setup.preview(provider: .claude, accounts: ["one"])
    let f = try #require(applyFailure { _ = try h.setup.apply(plan, io: io) })
    #expect(f.rollback.count == 1)
    #expect(f.rollback[0].contains("could not truncate") && f.rollback[0].contains("4000 bytes"))
    #expect(f.message.contains("Rollback was INCOMPLETE"))
    #expect(h.node(".claude-one") == .missing)  // 다른 단계는 되돌려짐
}
