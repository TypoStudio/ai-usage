import Foundation

/// 계정별 디렉토리 + 공통 환경 구성 (`~/.claude-<name>` + `~/.claude-shared`, `~/.codex-<name>` + `~/.codex-shared`).
///
/// 안전 원칙
/// - `preview` 는 읽기만 한다. 충돌이 하나라도 있으면 아무것도 하지 않고 `conflicts` 로 거절한다.
/// - `apply` 는 같은 계획을 다시 계산해 그사이 상태가 바뀌었으면 거절하고, 바꾸기 전에 대상 전부를 복사 백업한다.
/// - 삭제·덮어쓰기 없음: 디렉토리 생성, 이동(대상 없을 때만), 링크 생성(없을 때만), 새 파일 쓰기,
///   AI Usage 가 만든 헬퍼 교체, `.zshrc` 끝에 한 줄 추가만 한다. 중간 실패는 역순으로 되돌린다.
/// - 인증 파일(`.claude.json`, `.credentials.json`, `auth.json`)은 절대 공유하지 않고, 링크로 되어 있으면 거절한다.
/// - 키체인은 건드리지 않는다. 기본 `~/.claude` 에서 옮긴 Claude 계정은 macOS 에서 다시 로그인해야 한다.
public struct AuthenticationSetup: Sendable {
    public let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    public func preview(provider: ProviderKind, accounts: [String]) throws -> AuthenticationSetupPlan {
        guard let layout = Layout(provider) else { throw AuthenticationSetupError.unsupportedProvider(provider) }
        try Self.validate(accounts)
        var planner = Planner(layout: layout, home: homePath, requested: accounts)
        return try planner.plan()
    }

    public func apply(_ plan: AuthenticationSetupPlan) throws -> AuthenticationSetupResult {
        try apply(plan, io: .system)
    }

    /// `io` 는 테스트에서 쓰기 실패(파일 크기 제한 등)를 재현하는 데만 바꾼다
    func apply(_ plan: AuthenticationSetupPlan, io: FileIO) throws -> AuthenticationSetupResult {
        guard plan.home == homePath else { throw AuthenticationSetupError.planOutdated }
        let fresh = try preview(provider: plan.provider, accounts: plan.requested)
        guard fresh.ops == plan.ops, fresh.accounts == plan.accounts, fresh.backupSources == plan.backupSources else {
            throw AuthenticationSetupError.planOutdated
        }
        var warnings = plan.warnings
        guard !plan.ops.isEmpty else {
            warnings.append("Nothing to change; no backup was made.")
            return AuthenticationSetupResult(backupPath: "", accountPaths: plan.accountPaths,
                                             loginCommands: plan.loginCommands, warnings: warnings)
        }
        let backup = try makeBackup(plan)
        var undo: [(String, () throws -> Void)] = []
        for op in plan.ops {
            do {
                undo.append((op.describe(home: homePath), try Self.perform(op, io: io)))
            } catch {
                var rollbackFailures: [String] = []
                var reason = error
                if let failure = error as? OpFailure {
                    reason = failure.underlying
                    if let c = failure.cleanupFailure { rollbackFailures.append("\(op.describe(home: homePath)): \(c)") }
                }
                for (step, u) in undo.reversed() {
                    do { try u() } catch { rollbackFailures.append("\(step): \(error.localizedDescription)") }
                }
                throw AuthenticationSetupError.applyFailed(step: op.describe(home: homePath),
                                                           reason: reason.localizedDescription,
                                                           backupPath: backup, rollbackFailures: rollbackFailures)
            }
        }
        if plan.provider == .codex {
            warnings.append("Codex may replace the config.toml link with a regular file; `codex-account` reports it.")
        }
        return AuthenticationSetupResult(backupPath: backup, accountPaths: plan.accountPaths,
                                         loginCommands: plan.loginCommands, warnings: warnings)
    }

    var homePath: String { home.standardizedFileURL.path }

    // MARK: - Validation

    static let maxAccounts = 12

    static func validate(_ accounts: [String]) throws {
        guard !accounts.isEmpty else { throw AuthenticationSetupError.noAccounts }
        guard accounts.count <= maxAccounts else { throw AuthenticationSetupError.tooManyAccounts(maxAccounts) }
        var seen = Set<String>()
        for a in accounts {
            guard isValidName(a) else { throw AuthenticationSetupError.invalidAccountName(a) }
            guard seen.insert(a).inserted else { throw AuthenticationSetupError.duplicateAccount(a) }
        }
    }

    /// `shared` 는 공통 디렉토리, `sync` 는 헬퍼 하위 명령이라 금지
    static let reservedNames: Set<String> = ["shared", "sync"]

    /// 소문자·숫자로 시작하고 소문자·숫자·`-`·`_` 만, 32자 이하, 숫자만으로는 안 됨 (`1` 은 `one` 의 단축키·`cld1` 별칭).
    /// 이 문자 집합 덕분에 셸 스크립트에 그대로 넣어도 해석될 문자가 없다.
    static func isValidName(_ name: String) -> Bool {
        guard (1...32).contains(name.count), !reservedNames.contains(name),
              !name.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }) else { return false }
        let first = name.unicodeScalars.first!
        guard ("a"..."z").contains(first) || ("0"..."9").contains(first) else { return false }
        return name.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_"
        }
    }

    // MARK: - Backup

    func makeBackup(_ plan: AuthenticationSetupPlan) throws -> String {
        let fm = FileManager.default
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let base = "\(homePath)/\(plan.provider.rawValue)-setup-backup-\(f.string(from: Date()))"
        var dir = base
        var n = 1
        while true {
            // 로그인 정보가 들어가므로 소유자만 읽을 수 있게
            do {
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                break
            } catch {
                guard fm.fileExists(atPath: dir), n < 100 else {
                    throw AuthenticationSetupError.backupFailed(error.localizedDescription)
                }
                n += 1; dir = "\(base)-\(n)"
            }
        }
        var manifest = ["# AI Usage authentication setup backup", "# original path\tkind\tlink target", ""]
        // Runtime sockets and pipes cannot be backed up as regular files. Use a dedicated
        // manager to skip only those items; errors copying persistent files still stop setup.
        let copyFilter = BackupCopyFilter()
        let backupManager = FileManager()
        backupManager.delegate = copyFilter
        do {
            for src in plan.backupSources {
                let node = Node.at(src)
                switch node {
                case .missing:
                    continue
                case .symlink(let dest):
                    manifest.append("\(src)\tsymlink\t\(dest)")
                    // 링크만 남기면 데이터가 백업되지 않는다 — 대상 내용을 복사한다 (계정 링크는 대상 계정이 따로 복사됨)
                    guard !plan.linkOnlyBackups.contains(src) else { continue }
                    let target = URL(fileURLWithPath: src).resolvingSymlinksInPath().path
                    if Node.at(target) != .missing {
                        try backupManager.copyItem(atPath: target, toPath: "\(dir)/\((src as NSString).lastPathComponent)")
                    }
                default:
                    manifest.append("\(src)\t\(node.kind)\t")
                    try backupManager.copyItem(atPath: src, toPath: "\(dir)/\((src as NSString).lastPathComponent)")
                }
            }
            for (path, kind) in copyFilter.skipped.sorted(by: { $0.key < $1.key }) {
                manifest.append("\(path)\tskipped-\(kind)\t")
            }
            try Data((manifest.joined(separator: "\n") + "\n").utf8)
                .write(to: URL(fileURLWithPath: "\(dir)/backup-manifest.txt"), options: .withoutOverwriting)
        } catch {
            throw AuthenticationSetupError.backupFailed("\(error.localizedDescription) (partial backup at \(dir); nothing was changed)")
        }
        return dir
    }

    // MARK: - Operations

    /// 하나를 실행하고 되돌리는 클로저를 돌려준다. 모든 생성은 "없을 때만" 이라 기존 데이터를 덮지 않는다.
    /// 실행 도중 실패하면 그 작업이 남긴 부분 결과(쓰다 만 파일, 덧붙이다 만 줄)는 스스로 치우고,
    /// 치우지 못했으면 `OpFailure.cleanupFailure` 로 알린다.
    static func perform(_ op: Op, io: FileIO = .system) throws -> () throws -> Void {
        let fm = FileManager.default
        switch op {
        case .makeDir(let p):
            try fm.createDirectory(atPath: p, withIntermediateDirectories: false)
            return { if (try? fm.contentsOfDirectory(atPath: p))?.isEmpty == true { try fm.removeItem(atPath: p) } }
        case .move(let from, let to):
            guard Node.at(to) == .missing else { throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: to]) }
            try fm.moveItem(atPath: from, toPath: to)
            return { try fm.moveItem(atPath: to, toPath: from) }
        case .link(let at, let dest):
            try fm.createSymbolicLink(atPath: at, withDestinationPath: dest)
            return { if case .symlink = Node.at(at) { try fm.removeItem(atPath: at) } }
        case .copy(let from, let to):
            guard Node.at(from) == .file else { throw AuthenticationSetupError.planOutdated }
            let data = try Data(contentsOf: URL(fileURLWithPath: from))
            let mode = ((try? fm.attributesOfItem(atPath: from)[.posixPermissions]) as? Int).map { mode_t($0 & 0o777) } ?? 0o600
            try createFile(to, data, mode: mode, io: io)
            return { try fm.removeItem(atPath: to) }
        case .write(let p, let data, let mode):
            try createFile(p, data, mode: mode_t(mode), io: io)
            return { try fm.removeItem(atPath: p) }
        case .replace(let p, let old, let new):
            try replaceFile(p, old: old, new: new, io: io)
            return { try replaceFile(p, old: new, new: old, io: .system) }
        case .append(let p, let text):
            let size = try appendText(p, text, io: io)
            return {
                let fd = open(p, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw posixError() }
                defer { close(fd) }
                guard ftruncate(fd, size) == 0 else { throw posixError() }
            }
        }
    }

    /// `O_EXCL` 로 새로 만든 파일에만 쓴다 — 이미 있으면(남의 파일) 손대지 않고 실패.
    /// 쓰기·권한 설정·닫기 중 실패하면 이 호출이 만든 바로 그 파일(같은 inode)만 지운다.
    static func createFile(_ path: String, _ data: Data, mode: mode_t, io: FileIO) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard fd >= 0 else { throw posixError() }
        var created = stat()
        var isOpen = true
        let statOK = fstat(fd, &created) == 0
        do {
            guard statOK else { throw posixError() }
            try writeAll(fd, data, io: io)
            guard io.fchmod(fd, mode) == 0 else { throw posixError() }
            isOpen = false
            guard close(fd) == 0 else { throw posixError() }
        } catch {
            if isOpen { close(fd) }
            var now = stat()
            let cleanup: String?
            if lstat(path, &now) != 0 {
                cleanup = nil
            } else if created.st_ino != 0, now.st_dev == created.st_dev, now.st_ino == created.st_ino {
                cleanup = unlink(path) == 0 ? nil : "could not remove partial file \(path): \(posixError().localizedDescription)"
            } else {
                cleanup = "partial file \(path) could not be identified safely; left in place"
            }
            throw OpFailure(underlying: error, cleanupFailure: cleanup)
        }
    }

    /// 새 내용을 옆의 임시 파일에 다 쓴 뒤 rename — 원본은 그 순간까지 그대로
    static func replaceFile(_ path: String, old: Data, new: Data, io: FileIO) throws {
        guard Node.at(path) == .file, (try? Data(contentsOf: URL(fileURLWithPath: path))) == old else {
            throw AuthenticationSetupError.planOutdated
        }
        let mode = ((try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]) as? Int)
            .map { mode_t($0 & 0o777) } ?? 0o644
        let tmp = "\(path).aiusage-\(UUID().uuidString)"
        try createFile(tmp, new, mode: mode, io: io)
        guard rename(tmp, path) == 0 else {
            let error = posixError()
            throw OpFailure(underlying: error, cleanupFailure: unlink(tmp) == 0 ? nil : "could not remove temporary file \(tmp)")
        }
    }

    /// 끝에 덧붙이고 원래 길이를 돌려준다. 쓰다 실패하면 원래 길이로 잘라 부분 줄을 남기지 않는다.
    static func appendText(_ path: String, _ text: String, io: FileIO) throws -> off_t {
        let fd = open(path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixError() }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw posixError() }
        guard (st.st_mode & S_IFMT) == S_IFREG else { throw AuthenticationSetupError.planOutdated }
        let size = st.st_size
        var prefix = ""
        if size > 0 {
            var last: UInt8 = 0
            guard pread(fd, &last, 1, size - 1) == 1 else { throw posixError() }
            if last != UInt8(ascii: "\n") { prefix = "\n" }
        }
        do {
            guard lseek(fd, size, SEEK_SET) == size else { throw posixError() }
            try writeAll(fd, Data((prefix + "\n" + text).utf8), io: io)
        } catch {
            let cleanup = io.ftruncate(fd, size) == 0 ? nil
                : "could not truncate \(path) back to its original \(size) bytes: \(posixError().localizedDescription)"
            throw OpFailure(underlying: error, cleanupFailure: cleanup)
        }
        return size
    }

    static func writeAll(_ fd: Int32, _ data: Data, io: FileIO) throws {
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buf.count {
                let n = io.write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw n == 0 ? POSIXError(.EIO) : posixError() }
                offset += n
            }
        }
    }

    static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

/// Filters by file type without following symbolic links or changing source files.
private final class BackupCopyFilter: NSObject, FileManagerDelegate {
    private(set) var skipped: [String: String] = [:]

    func fileManager(_ fileManager: FileManager, shouldCopyItemAt srcURL: URL, to dstURL: URL) -> Bool {
        var info = stat()
        // Let copyItem report inspection and read failures instead of silently omitting data.
        guard lstat(srcURL.path, &info) == 0 else { return true }
        let kind: String
        switch info.st_mode & S_IFMT {
        case S_IFSOCK: kind = "socket"
        case S_IFIFO: kind = "fifo"
        default: return true
        }
        skipped[srcURL.path] = kind
        return false
    }
}

/// 실제 파일 쓰기 시스템 호출. 테스트가 부분 쓰기·권한 실패를 재현할 때만 바꾼다.
struct FileIO: Sendable {
    var write: @Sendable (Int32, UnsafeRawPointer, Int) -> Int = { Darwin.write($0, $1, $2) }
    var fchmod: @Sendable (Int32, mode_t) -> Int32 = { Darwin.fchmod($0, $1) }
    var ftruncate: @Sendable (Int32, off_t) -> Int32 = { Darwin.ftruncate($0, $1) }
    static let system = FileIO()
}

/// 작업 하나가 실패했고, 그 작업 자신의 부분 결과를 치우지 못했으면 `cleanupFailure` 에 이유
struct OpFailure: Error {
    let underlying: Error
    let cleanupFailure: String?
}

// MARK: - Public types

public struct AuthenticationSetupPlan: Sendable {
    public let provider: ProviderKind
    /// 관리할 계정 (요청 순서, 현재 `~/.claude` 가 가리키는 계정이 목록 밖이면 끝에 추가됨)
    public let accounts: [String]
    public let summary: [String]
    public let warnings: [String]

    let home: String
    let requested: [String]
    let ops: [Op]
    let backupSources: [String]
    /// 계정 디렉토리를 가리키는 `~/.claude` 링크 — 대상은 계정 백업으로 이미 복사되므로 링크만 기록
    let linkOnlyBackups: Set<String>
    let accountPaths: [String]
    let loginCommands: [String]
}

public struct AuthenticationSetupResult: Sendable {
    /// 바뀐 것이 없으면 빈 문자열 (백업하지 않음)
    public let backupPath: String
    public let accountPaths: [String]
    public let loginCommands: [String]
    public let warnings: [String]
}

public enum AuthenticationSetupError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedProvider(ProviderKind)
    case noAccounts
    case tooManyAccounts(Int)
    case invalidAccountName(String)
    case duplicateAccount(String)
    case homeNotFound(String)
    case conflicts([String])
    case planOutdated
    case backupFailed(String)
    case applyFailed(step: String, reason: String, backupPath: String, rollbackFailures: [String])

    public var errorDescription: String? {
        switch self {
        case .unsupportedProvider(let p):
            return "\(p.title) does not support separate account directories."
        case .noAccounts:
            return "Add at least one account name."
        case .tooManyAccounts(let n):
            return "At most \(n) accounts are supported."
        case .invalidAccountName(let n):
            return "Invalid account name \"\(n)\". Use 1–32 lowercase letters, digits, '-' or '_', starting with a letter or digit and not only digits; \"shared\" and \"sync\" are reserved."
        case .duplicateAccount(let n):
            return "Account \"\(n)\" is listed more than once."
        case .homeNotFound(let p):
            return "Home directory not found: \(p)"
        case .conflicts(let items):
            return "Setup refused; nothing was changed. Resolve these first:\n" + items.map { "• \($0)" }.joined(separator: "\n")
        case .planOutdated:
            return "Files changed since the preview. Preview again before applying."
        case .backupFailed(let r):
            return "Backup failed: \(r)"
        case let .applyFailed(step, reason, backup, rollbackFailures):
            if rollbackFailures.isEmpty {
                return "Failed at \"\(step)\": \(reason). All changes were rolled back. Backup: \(backup)"
            }
            return "Failed at \"\(step)\": \(reason). Rollback was INCOMPLETE; restore these from the backup at \(backup):\n"
                + rollbackFailures.map { "• \($0)" }.joined(separator: "\n")
        }
    }
}

// MARK: - Layout

struct Layout: Sendable {
    let provider: ProviderKind
    /// `.claude` — 활성 계정으로의 링크
    let linkName: String
    let sharedName: String
    let sharedFiles: [String]
    let sharedDirs: [String]
    /// 계정마다 따로 — 링크면 거절
    let authFiles: [String]
    /// 어느 계정에도 없을 때 공통 디렉토리에 만들어 두는 최소 파일 — 없으면 CLI 가 계정마다 따로 만들어 공유가 깨진다
    let seedFiles: [String: Data]
    let helperName: String
    let envVar: String
    let command: String
    let functionName: String

    init?(_ provider: ProviderKind) {
        self.provider = provider
        switch provider {
        case .claude:
            linkName = ".claude"; sharedName = ".claude-shared"
            sharedFiles = ["settings.json", "settings.local.json", "CLAUDE.md", "keybindings.json", "history.jsonl", ".omc-config.json"]
            sharedDirs = ["skills", "plugins", "hooks", "hud", "projects", "plans", "file-history", "downloads", "chrome"]
            authFiles = [".claude.json", ".credentials.json"]
            seedFiles = ["settings.json": Data("{}\n".utf8)]
            helperName = "claude-account.zsh"; envVar = "CLAUDE_CONFIG_DIR"; command = "claude"; functionName = "claude-account"
        case .codex:
            linkName = ".codex"; sharedName = ".codex-shared"
            sharedFiles = ["config.toml", "hooks.json"]
            sharedDirs = ["skills", "plugins", "rules", "memories", "computer-use"]
            authFiles = ["auth.json"]
            seedFiles = ["config.toml": Data()]
            helperName = "codex-account.zsh"; envVar = "CODEX_HOME"; command = "codex"; functionName = "codex-account"
        case .antigravity:
            return nil
        }
    }

    var prefix: String { linkName + "-" }
    var privateNote: String {
        provider == .claude
            ? ".claude.json (login, MCP list), .credentials.json, sessions, session-env, cache, debug, ide, backups, paste-cache and everything else"
            : "auth.json, sessions, sqlite databases, logs and everything else"
    }
}

// MARK: - Filesystem node

enum Node: Equatable, Sendable {
    case missing, file, directory, symlink(String), other

    /// 마지막 경로 성분의 링크는 따라가지 않는다 (lstat)
    static func at(_ path: String) -> Node {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path), let type = attrs[.type] as? FileAttributeType else {
            return .missing
        }
        switch type {
        case .typeRegular: return .file
        case .typeDirectory: return .directory
        case .typeSymbolicLink: return .symlink((try? fm.destinationOfSymbolicLink(atPath: path)) ?? "")
        default: return .other
        }
    }

    var kind: String {
        switch self {
        case .missing: return "missing"
        case .file: return "file"
        case .directory: return "directory"
        case .symlink: return "symlink"
        case .other: return "special file"
        }
    }

    var exists: Bool { self != .missing }
}

// MARK: - Operations

enum Op: Equatable, Sendable {
    case makeDir(String)
    case move(String, String)
    /// 링크 경로, 대상 (절대 경로)
    case link(String, String)
    case copy(String, String)
    case write(String, Data, Int)
    /// AI Usage 가 만든 헬퍼만 교체 — 미리보기 때 읽은 내용과 같을 때만
    case replace(String, old: Data, new: Data)
    case append(String, String)

    func describe(home: String) -> String {
        let t = { (p: String) in tilde(p, home: home) }
        switch self {
        case .makeDir(let p): return "Create \(t(p))/"
        case .move(let a, let b): return "Move \(t(a)) → \(t(b))"
        case .link(let a, let b): return "Link \(t(a)) → \(t(b))"
        case .copy(let a, let b): return "Copy \(t(a)) → \(t(b))"
        case .write(let p, _, _): return "Write \(t(p))"
        case .replace(let p, _, _): return "Regenerate \(t(p))"
        case .append(let p, _): return "Add source line to \(t(p))"
        }
    }
}

func tilde(_ path: String, home: String) -> String {
    path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}

// MARK: - Planner

/// 읽기 전용 조사 → 작업 목록. 같은 상태에서는 항상 같은 결과 (apply 재검증에 쓰임).
struct Planner {
    let layout: Layout
    let home: String
    let requested: [String]

    var ops: [Op] = []
    var summary: [String] = []
    var warnings: [String] = []
    var conflicts: [String] = []
    /// 계정 이름 → 지금 내용이 있는 곳 (옮겨질 계정은 `~/.claude`, 나머지는 계정 디렉토리)
    var sources: [String: String] = [:]

    init(layout: Layout, home: String, requested: [String]) {
        self.layout = layout; self.home = home; self.requested = requested
    }

    func accountPath(_ n: String) -> String { "\(home)/\(layout.prefix)\(n)" }
    var linkPath: String { "\(home)/\(layout.linkName)" }
    var sharedPath: String { "\(home)/\(layout.sharedName)" }
    func t(_ p: String) -> String { tilde(p, home: home) }
    func source(_ n: String) -> String { sources[n] ?? accountPath(n) }

    mutating func plan() throws -> AuthenticationSetupPlan {
        guard Node.at(URL(fileURLWithPath: home).resolvingSymlinksInPath().path) == .directory else {
            throw AuthenticationSetupError.homeNotFound(home)
        }
        var accounts = requested
        var linkOnly = Set<String>()

        // 1. ~/.claude 상태 → 활성 계정, 옮길 원본
        var migrateFrom: String?
        var createLink = false
        let active: String
        switch Node.at(linkPath) {
        case .missing:
            active = accounts[0]; createLink = true
        case .directory:
            active = accounts[0]; migrateFrom = linkPath; createLink = true
            if Node.at(accountPath(active)).exists {
                conflicts.append("\(t(linkPath)) is a directory and \(t(accountPath(active))) already exists; move one of them aside, or put an unused name first.")
            }
        case .symlink(let dest):
            linkOnly.insert(linkPath)
            if let name = accountName(linkTarget: dest), Node.at(accountPath(name)) == .directory {
                active = name
                if !accounts.contains(name) {
                    accounts.append(name)
                    warnings.append("\(t(linkPath)) currently points to \"\(name)\"; it stays active and is added to the managed accounts.")
                }
            } else {
                conflicts.append("\(t(linkPath)) is a link to \(dest), which is not an existing \(t(home))/\(layout.prefix)<name> directory.")
                active = accounts[0]
            }
        case .file, .other:
            conflicts.append("\(t(linkPath)) is a \(Node.at(linkPath).kind), not a directory or link.")
            active = accounts[0]
        }

        // 2. 계정 디렉토리
        var newAccounts: [String] = []
        for n in accounts {
            let p = accountPath(n)
            switch Node.at(p) {
            case .missing where migrateFrom != nil && n == active: break
            case .missing: newAccounts.append(n)
            case .directory: break
            case .symlink(let d):
                conflicts.append("\(t(p)) is a link to \(d); account directories must be real directories so logins stay separate.")
            case let other:
                conflicts.append("\(t(p)) is a \(other.kind), not a directory.")
            }
        }
        if let from = migrateFrom { sources[active] = from }
        for n in accounts {
            for f in layout.authFiles {
                if case .symlink(let d) = Node.at("\(source(n))/\(f)") {
                    conflicts.append("\(t(source(n)))/\(f) is a link to \(d); login files must never be shared between accounts.")
                }
            }
        }
        switch Node.at(sharedPath) {
        case .missing, .directory: break
        case .symlink where Node.at(URL(fileURLWithPath: sharedPath).resolvingSymlinksInPath().path) == .directory: break
        case let other: conflicts.append("\(t(sharedPath)) is a \(other.kind), not a directory.")
        }
        checkSharedOverlap(accounts: accounts)
        if !conflicts.isEmpty { throw AuthenticationSetupError.conflicts(conflicts) }

        // 3. 이동 · 생성
        summary.append("\(layout.provider.title) accounts: " + accounts.joined(separator: ", ") + " (active: \(active))")
        if let from = migrateFrom {
            ops.append(.move(from, accountPath(active)))
            ops.append(.link(linkPath, accountPath(active)))
        }
        for n in newAccounts { ops.append(.makeDir(accountPath(n))) }
        if migrateFrom == nil && createLink { ops.append(.link(linkPath, accountPath(active))) }
        if Node.at(sharedPath) == .missing { ops.append(.makeDir(sharedPath)) }

        var needsLogin = Set(newAccounts)
        if layout.provider == .claude {
            planClaudeConfigCopy(active: active, migrating: migrateFrom != nil || createLink, needsLogin: &needsLogin)
        }

        // 4. 공통 항목
        for item in layout.sharedFiles { planShared(item, isDir: false, accounts: accounts) }
        for item in layout.sharedDirs { planShared(item, isDir: true, accounts: accounts) }
        if layout.provider == .codex { planAgentsLink(accounts: accounts) }
        if !conflicts.isEmpty { throw AuthenticationSetupError.conflicts(conflicts) }
        summary.append("Kept per account (never shared): \(layout.privateNote).")

        // 5. MCP · 헬퍼 · .zshrc
        if layout.provider == .claude { planMCP(accounts: accounts, active: active, migrating: migrateFrom != nil || createLink) }
        planHelper(accounts: accounts)
        planZshrc()

        // 6. 로그인 · 경고
        for n in accounts where !isLoggedIn(n) { needsLogin.insert(n) }
        let loginCommands = accounts.filter(needsLogin.contains).map(loginCommand)
        if !loginCommands.isEmpty {
            summary.append("Log in afterwards: " + accounts.filter(needsLogin.contains).joined(separator: ", "))
        }
        let others = otherAccountDirs(managed: accounts)
        if !others.isEmpty {
            summary.append("Not managed (left untouched): " + others.map(t).joined(separator: ", "))
        }
        if !ops.isEmpty {
            warnings.insert("Quit every running \(layout.provider.title) session (terminal and IDE) before applying; their files are moved while they may be open. Pausing AI Usage refresh does not cover them.", at: 0)
            summary.append("Files are backed up to ~/\(layout.provider.rawValue)-setup-backup-<date>/ before any change; runtime sockets and pipes are excluded and recorded in the backup manifest.")
        } else {
            summary.append("Already set up; nothing to change.")
        }

        var backupSources = [linkPath] + accounts.map(accountPath) + [sharedPath]
        if layout.provider == .claude { backupSources.append("\(home)/.claude.json") }
        backupSources.append("\(home)/.zshrc")

        return AuthenticationSetupPlan(
            provider: layout.provider, accounts: accounts,
            summary: summary + ops.map { $0.describe(home: home) }, warnings: warnings,
            home: home, requested: requested, ops: ops,
            backupSources: backupSources.filter { Node.at($0).exists }, linkOnlyBackups: linkOnly,
            accountPaths: accounts.map(accountPath), loginCommands: loginCommands)
    }

    /// 공통 디렉토리(링크면 실제 위치)가 홈·`~/.claude`·계정 디렉토리와 같거나 서로 포함하면
    /// 자기 자신으로의 이동이나 순환 링크가 생기므로 거절한다.
    mutating func checkSharedOverlap(accounts: [String]) {
        guard Node.at(sharedPath).exists else { return }
        let real = { (p: String) in URL(fileURLWithPath: p).resolvingSymlinksInPath().standardizedFileURL.path }
        let shared = real(sharedPath)
        let inside = { (a: String, b: String) in a == b || a.hasPrefix(b == "/" ? "/" : b + "/") }
        if inside(real(home), shared) {
            conflicts.append("\(t(sharedPath)) resolves to \(shared), which contains the home directory.")
            return
        }
        let roots = [linkPath] + accounts.map(accountPath) + otherAccountDirs(managed: accounts)
        for root in roots where Node.at(root).exists {
            let r = real(root)
            if inside(shared, r) || inside(r, shared) {
                conflicts.append("\(t(sharedPath)) resolves to \(shared), which overlaps \(t(root)) (\(r)); the shared directory must be separate from account directories.")
            }
        }
    }

    /// 파일만 보고 판단한다 (키체인 조회 없음). Claude 는 `.claude.json` 의 `oauthAccount` —
    /// setup 이 만든 `mcpServers` 만 있는 파일은 로그인 전으로 본다. Codex 는 `auth.json`.
    func isLoggedIn(_ n: String) -> Bool {
        if layout.provider == .codex { return Node.at("\(source(n))/auth.json") == .file }
        let path = "\(source(n))/.claude.json"
        guard Node.at(path) == .file, let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return obj["oauthAccount"] is [String: Any]
    }

    /// `~/.claude` 링크 대상이 `~/.claude-<유효한 이름>` 이면 그 이름
    func accountName(linkTarget dest: String) -> String? {
        let abs = dest.hasPrefix("/") ? dest : "\(home)/\(dest)"
        let std = URL(fileURLWithPath: abs).standardizedFileURL.path
        guard std.hasPrefix("\(home)/\(layout.prefix)") else { return nil }
        let name = String(std.dropFirst("\(home)/\(layout.prefix)".count))
        return AuthenticationSetup.isValidName(name) ? name : nil
    }

    func pointsTo(_ linkPath: String, dest: String, target: String) -> Bool {
        let abs = dest.hasPrefix("/") ? dest : "\((linkPath as NSString).deletingLastPathComponent)/\(dest)"
        let a = URL(fileURLWithPath: abs), b = URL(fileURLWithPath: target)
        return a.standardizedFileURL.path == b.standardizedFileURL.path
            || a.resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path
    }

    mutating func planShared(_ item: String, isDir: Bool, accounts: [String]) {
        let shared = "\(sharedPath)/\(item)"
        var sharedExists: Bool
        switch Node.at(shared) {
        case .missing: sharedExists = false
        case .directory where isDir, .file where !isDir, .symlink: sharedExists = true
        case let other:
            conflicts.append("\(t(shared)) is a \(other.kind); expected a \(isDir ? "directory" : "file").")
            return
        }
        var holders: [String] = [], needLink: [String] = [], foreign: [String] = []
        for n in accounts {
            let p = "\(source(n))/\(item)"
            switch Node.at(p) {
            case .missing: needLink.append(n)
            case .symlink(let d):
                if !pointsTo(p, dest: d, target: shared) { foreign.append(n); warnings.append("Kept existing link \(t(p)) → \(d).") }
            case .directory where isDir, .file where !isDir: holders.append(n)
            case let other:
                conflicts.append("\(t(p)) is a \(other.kind); expected a \(isDir ? "directory" : "file").")
            }
        }
        if sharedExists {
            for n in holders {
                conflicts.append("\(t(source(n)))/\(item) and \(t(shared)) both exist; keep one (compare them and move the other aside).")
            }
        } else if holders.count > 1 {
            conflicts.append("\(item) exists in several accounts (\(holders.joined(separator: ", "))); keep only one copy before sharing it.")
        } else if let h = holders.first {
            ops.append(.move("\(accountPath(h))/\(item)", shared))
            ops.append(.link("\(accountPath(h))/\(item)", shared))
            sharedExists = true
        } else if !foreign.isEmpty {
            summary.append("\(item): not shared, because an account already links it elsewhere.")
            return
        } else if isDir {
            ops.append(.makeDir(shared))
            sharedExists = true
        } else if let seed = layout.seedFiles[item] {
            ops.append(.write(shared, seed, 0o644))
            sharedExists = true
        } else {
            // 형식을 확신할 수 없는 선택 파일은 만들지 않는다 — 생긴 뒤 다시 실행하면 공유된다
            if !needLink.isEmpty { summary.append("\(item): not found in any account; not shared until it exists (run setup again then).") }
            return
        }
        guard sharedExists, holders.count <= 1 else { return }
        for n in needLink { ops.append(.link("\(accountPath(n))/\(item)", shared)) }
    }

    /// Codex `AGENTS.md` → `~/.claude-shared/response-format.md` (있을 때만)
    mutating func planAgentsLink(accounts: [String]) {
        let target = "\(home)/.claude-shared/response-format.md"
        guard Node.at(target).exists else {
            summary.append("AGENTS.md: skipped (\(t(target)) not found).")
            return
        }
        for n in accounts {
            let p = "\(source(n))/AGENTS.md"
            switch Node.at(p) {
            case .missing: ops.append(.link("\(accountPath(n))/AGENTS.md", target))
            case .symlink(let d) where pointsTo(p, dest: d, target: target): break
            default: warnings.append("Kept existing \(t(p)); not linked to \(t(target)).")
            }
        }
    }

    /// 기본 위치 `~/.claude.json` (로그인 계정·MCP 목록)을 첫 계정에 복사. 원본은 그대로 둔다.
    mutating func planClaudeConfigCopy(active: String, migrating: Bool, needsLogin: inout Set<String>) {
        guard migrating else { return }
        let global = "\(home)/.claude.json"
        let dest = "\(source(active))/.claude.json"
        let hadDefaultSetup = Node.at(linkPath) == .directory || Node.at(global).exists
        switch Node.at(global) {
        case .file where Node.at(dest) == .missing:
            ops.append(.copy(global, "\(accountPath(active))/.claude.json"))
        case .file:
            warnings.append("\(t(dest)) already exists; \(t(global)) was not copied.")
        case .missing: break
        case let other:
            warnings.append("\(t(global)) is a \(other.kind); it was not copied.")
        }
        if hadDefaultSetup {
            needsLogin.insert(active)
            warnings.append("Claude Code stores the login for the default ~/.claude in the macOS keychain under a name tied to the directory path. It is not copied, so run /login once for \"\(active)\" after setup. The old keychain item and ~/.claude.json are left untouched.")
        }
    }

    /// `mcp.json` 이 없으면 기존 목록을 추출하고, `.claude.json` 이 없는 계정에는 `mcpServers` 만 담은 파일을 만든다
    /// (로그인 정보는 복사하지 않음). 이미 있는 `.claude.json` 은 건드리지 않는다 — 덮어쓰기는 명시적 sync 때만.
    mutating func planMCP(accounts: [String], active: String, migrating: Bool) {
        let mcp = "\(sharedPath)/mcp.json"
        var servers: [String: Any]?
        if Node.at(mcp) == .missing {
            var from = "\(source(active))/.claude.json"
            if migrating, Node.at("\(home)/.claude.json") == .file, Node.at(from) == .missing { from = "\(home)/.claude.json" }
            guard Node.at(from) == .file, let found = Self.mcpServers(at: from), !found.isEmpty,
                  let out = Self.mcpJSON(found) else {
                summary.append("MCP: no servers found; mcp.json not created, so sync does nothing until you add \(t(mcp)).")
                return
            }
            servers = found
            ops.append(.write(mcp, out, 0o600))
            summary.append("MCP: \(found.count) server(s) from \(t(from)) become the shared list.")
        } else if let found = Self.mcpServers(at: mcp) {
            servers = found
            summary.append("MCP: using existing \(t(mcp)).")
        } else {
            warnings.append("\(t(mcp)) has no valid \"mcpServers\" object; sync will refuse to run until it is fixed.")
        }
        if let servers, let seed = Self.mcpJSON(servers) {
            for n in accounts {
                let dest = "\(accountPath(n))/.claude.json"
                let copied = ops.contains { if case .copy(_, dest) = $0 { return true } else { return false } }
                if Node.at("\(source(n))/.claude.json") == .missing && !copied {
                    ops.append(.write(dest, seed, 0o600))
                }
            }
        }
        warnings.append("Switching accounts or `claude-account sync` replaces each account's MCP servers with mcp.json; servers added with `claude mcp add` are overwritten unless also added to mcp.json.")
    }

    static func mcpServers(at path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return obj["mcpServers"] as? [String: Any]
    }

    static func mcpJSON(_ servers: [String: Any]) -> Data? {
        (try? JSONSerialization.data(withJSONObject: ["mcpServers": servers],
                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
            .map { $0 + Data("\n".utf8) }
    }

    mutating func planHelper(accounts: [String]) {
        let path = "\(sharedPath)/\(layout.helperName)"
        let script = Data(HelperScript(layout: layout, accounts: accounts).text.utf8)
        switch Node.at(path) {
        case .missing:
            ops.append(.write(path, script, 0o644))
        case .file:
            let old = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
            if old == script { break }
            if old.starts(with: Data(HelperScript.marker.utf8)) {
                ops.append(.replace(path, old: old, new: script))
            } else {
                warnings.append("\(t(path)) was not created by AI Usage; it is left unchanged, so `\(layout.functionName)` may not match these accounts.")
            }
        default:
            warnings.append("\(t(path)) is a \(Node.at(path).kind); helper not written.")
        }
    }

    mutating func planZshrc() {
        let zshrc = "\(home)/.zshrc"
        let helper = "$HOME/\(layout.sharedName)/\(layout.helperName)"
        let block = "# AI Usage: \(layout.provider.title) account helper\n[[ -r \"\(helper)\" ]] && source \"\(helper)\"\n"
        switch Node.at(zshrc) {
        case .missing:
            ops.append(.write(zshrc, Data(block.utf8), 0o644))
        case .file:
            let text = (try? String(contentsOfFile: zshrc, encoding: .utf8)) ?? ""
            if !text.contains("\(layout.sharedName)/\(layout.helperName)") { ops.append(.append(zshrc, block)) }
        default:
            warnings.append("~/.zshrc is a \(Node.at(zshrc).kind); not edited. Add this line yourself: source \"\(helper)\"")
        }
    }

    func otherAccountDirs(managed: [String]) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []
        return names.filter { $0.hasPrefix(layout.prefix) }
            .filter { n in
                let s = String(n.dropFirst(layout.prefix.count))
                return s != "shared" && !managed.contains(s) && Node.at("\(home)/\(n)") == .directory
            }
            .sorted().map { "\(home)/\($0)" }
    }

    func loginCommand(_ n: String) -> String {
        let q = shellQuote(accountPath(n))
        return layout.provider == .claude
            ? "\(layout.envVar)=\(q) claude   # then run /login"
            : "\(layout.envVar)=\(q) codex login"
    }
}

func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

// MARK: - Shell helper

/// `~/.claude-shared/claude-account.zsh` / `~/.codex-shared/codex-account.zsh`.
/// 계정 이름은 검증된 `[a-z0-9_-]` 뿐이고, 경로는 실행 시점의 `$HOME` 으로 만든다.
struct HelperScript {
    static let marker = "# Generated by AI Usage"
    let layout: Layout
    let accounts: [String]

    /// one → 1 … nine → 9, 나머지는 첫 글자가 겹치지 않을 때만 (team → t)
    var shortcuts: [(String, String)] {
        var result: [(String, String)] = []
        var used = Set(accounts)
        for a in accounts {
            if let i = AccountDiscovery.numberWords.firstIndex(of: a) {
                let k = String(i + 1)
                if used.insert(k).inserted { result.append((k, a)) }
            }
        }
        let firsts = accounts.filter { !AccountDiscovery.numberWords.contains($0) }.map { String($0.prefix(1)) }
        for a in accounts where !AccountDiscovery.numberWords.contains(a) {
            let k = String(a.prefix(1))
            if a.count > 1, firsts.filter({ $0 == k }).count == 1, used.insert(k).inserted { result.append((k, a)) }
        }
        return result
    }

    func aliasName(_ a: String) -> String {
        let p = layout.provider.labelPrefix
        if let i = AccountDiscovery.numberWords.firstIndex(of: a) { return "\(p)\(i + 1)" }
        return "\(p)\(a)"
    }

    var text: String {
        let fn = layout.functionName
        let v = layout.envVar
        let pre = layout.linkName
        let arr = layout.provider == .claude ? "CLAUDE_ACCOUNTS" : "CODEX_ACCOUNTS"
        let ns = "_\(layout.provider.rawValue)_account"
        let cases = accounts.map { a in
            let keys = [a] + shortcuts.filter { $0.1 == a }.map(\.0)
            return "    \(keys.joined(separator: "|"))) print -r -- \(a) ;;"
        }.joined(separator: "\n")
        let usage = accounts.map { a in ([a] + shortcuts.filter { $0.1 == a }.map(\.0)).joined(separator: "|") }
            .joined(separator: " | ")
        let aliases = accounts.map { "alias \(aliasName($0))='\(v)=\"$HOME/\(pre)-\($0)\" \(layout.command)'" }
            .joined(separator: "\n")

        var s = #"""
        \#(Self.marker) — \#(layout.provider.title) account switching. Re-running setup regenerates this file.
        # ~/\#(pre) is a symlink to the active ~/\#(pre)-<name>; shared settings live in ~/\#(layout.sharedName).
        \#(arr)=(\#(accounts.joined(separator: " ")))

        \#(ns)_current() {
          local t
          t=$(readlink "$HOME/\#(pre)" 2>/dev/null) || return 1
          [[ $t == /* ]] || t="$HOME/$t"
          print -r -- "${t%/}"
        }
        \#(ns)_dir=$(\#(ns)_current) && export \#(v)="$\#(ns)_dir"
        unset \#(ns)_dir

        \#(ns)_resolve() {
          case $1 in
        \#(cases)
            *) return 1 ;;
          esac
        }

        """#
        if layout.provider == .claude {
            s += #"""
            claude-mcp-sync() {
              local src="$HOME/.claude-shared/mcp.json" a f tmp rc=0
              if [[ ! -f $src ]]; then print -u2 "claude-mcp-sync: $src not found; nothing to sync"; return 0; fi
              if ! command -v jq >/dev/null 2>&1; then print -u2 "claude-mcp-sync: jq is required"; return 1; fi
              if ! jq -e '.mcpServers | type == "object"' "$src" >/dev/null 2>&1; then
                print -u2 "claude-mcp-sync: $src has no mcpServers object"; return 1
              fi
              for a in $CLAUDE_ACCOUNTS; do
                f="$HOME/.claude-$a/.claude.json"
                if [[ -L "$HOME/.claude-$a" || -L $f ]]; then
                  print -u2 "claude-mcp-sync: skipped $a (symlinked login file; refusing to write through it)"; rc=1; continue
                fi
                [[ -d "$HOME/.claude-$a" ]] || continue
                if [[ -e $f && ! -f $f ]]; then print -u2 "claude-mcp-sync: skipped $a ($f is not a regular file)"; rc=1; continue; fi
                if [[ -f $f ]] && ! jq -e -s 'length == 1 and (.[0] | type == "object")' "$f" >/dev/null 2>&1; then
                  print -u2 "claude-mcp-sync: skipped $a ($f is not a single JSON object; left unchanged)"; rc=1; continue
                fi
                tmp=$(mktemp "$f.XXXXXX") || return 1
                # .claude.json 이 없는 계정은 mcpServers 만 담아 새로 만든다 (로그인 정보 없음)
                if { if [[ -f $f ]]; then jq --slurpfile m "$src" '.mcpServers = $m[0].mcpServers' "$f"
                     else jq -n --slurpfile m "$src" '{mcpServers: $m[0].mcpServers}'; fi } >| "$tmp" \
                  && [[ -s $tmp ]] && chmod 600 "$tmp" && mv -f "$tmp" "$f"; then
                  :
                else
                  rm -f "$tmp"; print -u2 "claude-mcp-sync: failed to update $f"; rc=1
                fi
              done
              return $rc
            }

            _claude_account_email() {
              local f="$HOME/.claude-$1/.claude.json" e
              if [[ -f $f ]] && command -v jq >/dev/null 2>&1; then
                e=$(jq -r '.oauthAccount.emailAddress // empty' "$f" 2>/dev/null)
              fi
              print -r -- "${e:--}"
            }

            """#
        } else {
            s += #"""
            _codex_account_email() {
              local f="$HOME/.codex-$1/auth.json" p e
              if [[ -f $f ]] && command -v jq >/dev/null 2>&1; then
                p=$(jq -r '.tokens.id_token // empty' "$f" 2>/dev/null)
                p=${${p#*.}%%.*}
                if [[ -n $p ]]; then
                  p=${p//-/+}; p=${p//_//}
                  while (( ${#p} % 4 )); do p+='='; done
                  e=$(print -r -- "$p" | base64 -d 2>/dev/null | jq -r '.email // empty' 2>/dev/null)
                fi
              fi
              print -r -- "${e:--}"
            }

            """#
        }
        let extraStatus = layout.provider == .codex ? [
            #"    if [[ -e "$HOME/.codex-shared/config.toml" && ! -L "$HOME/.codex-$a/config.toml" ]]; then"#,
            #"      print -r -- "    ! config.toml is not linked to ~/.codex-shared (Codex may have rewritten it)""#,
            "    fi",
        ].joined(separator: "\n") : ""
        let syncCase = layout.provider == .claude ? "\n    sync) claude-mcp-sync; return ;;" : ""
        let syncUsage = layout.provider == .claude ? "sync | " : ""
        let afterSwitch = layout.provider == .claude
            ? "\n  claude-mcp-sync || { rc=$?; print -u2 \"\(fn): switched, but MCP sync failed\"; }" : ""
        s += #"""
        \#(ns)_status() {
          local cur a mark
          cur=$(\#(ns)_current)
          for a in $\#(arr); do
            mark=' '; [[ $cur == "$HOME/\#(pre)-$a" ]] && mark='*'
            print -r -- "$mark $a  $(\#(ns)_email $a)"
        \#(extraStatus)
          done
        }

        \#(fn)() {
          case $1 in
            "") \#(ns)_status; return ;;\#(syncCase)
          esac
          local name dir rc=0
          if ! name=$(\#(ns)_resolve "$1"); then
            print -u2 "usage: \#(fn) [\#(syncUsage)\#(usage)]"; return 1
          fi
          dir="$HOME/\#(pre)-$name"
          if [[ ! -d $dir || -L $dir ]]; then print -u2 "\#(fn): $dir is not an account directory"; return 1; fi
          if [[ -e "$HOME/\#(pre)" && ! -L "$HOME/\#(pre)" ]]; then
            print -u2 "\#(fn): ~/\#(pre) is not a symlink; refusing to replace it"; return 1
          fi
          ln -sfn "$dir" "$HOME/\#(pre)" || return 1
          export \#(v)="$dir"\#(afterSwitch)
          \#(ns)_status
          return $rc
        }

        \#(aliases)

        """#
        return s
    }
}
