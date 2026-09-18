import Foundation

/// 서브프로세스 실행. Finder 에서 띄운 앱은 PATH 가 짧으므로 흔한 위치를 붙여 준다.
enum Shell {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path

    static var path: String {
        ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
            .joined(separator: ":")
    }

    struct Result: Sendable { var status: Int32; var stdout: Data; var timedOut: Bool }

    /// stdin 은 닫고, `timeout` 초가 지나면 SIGTERM → 3초 뒤 SIGKILL.
    /// stdout 은 파이프 대신 임시 파일로 받는다 — 자식이 띄운 손자 프로세스가 출력을 물고 있어도 막히지 않는다.
    static func run(_ executable: String, _ args: [String], env extra: [String: String] = [:],
                    timeout: TimeInterval, captureOutput: Bool = true) async -> Result {
        await withCheckedContinuation { cont in
            let once = ResumeOnce(cont)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = path
            env.merge(extra) { _, new in new }
            p.environment = env
            let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("aiusage-\(UUID().uuidString)")
            FileManager.default.createFile(atPath: outURL.path, contents: nil)
            let outHandle = captureOutput ? (try? FileHandle(forWritingTo: outURL)) : nil
            p.standardOutput = outHandle ?? FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice

            @Sendable func finish(status: Int32, timedOut: Bool) {
                try? outHandle?.close()
                let data = (try? Data(contentsOf: outURL)) ?? Data()
                try? FileManager.default.removeItem(at: outURL)
                once.resume(Result(status: status, stdout: data, timedOut: timedOut))
            }
            p.terminationHandler = { proc in finish(status: proc.terminationStatus, timedOut: false) }
            do { try p.run() } catch {
                finish(status: -1, timedOut: false)
                return
            }
            let pid = p.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard p.isRunning else { return }
                p.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                    if p.isRunning { kill(pid, SIGKILL) }
                    finish(status: -1, timedOut: true)
                }
            }
        }
    }

    /// 사용자가 지정한 경로 → PATH 후보 → `~/.local/share/claude/versions/*` 최신
    static func locate(_ name: String, override: String?) -> String? {
        let fm = FileManager.default
        if let o = override?.trimmingCharacters(in: .whitespaces), !o.isEmpty {
            let expanded = (o as NSString).expandingTildeInPath
            return fm.isExecutableFile(atPath: expanded) ? expanded : nil
        }
        for dir in path.split(separator: ":") where fm.isExecutableFile(atPath: "\(dir)/\(name)") {
            return "\(dir)/\(name)"
        }
        if name == "claude" {
            let vdir = "\(home)/.local/share/claude/versions"
            let versions = (try? fm.contentsOfDirectory(atPath: vdir)) ?? []
            if let latest = versions.sorted(by: { $0.compare($1, options: .numeric) == .orderedAscending }).last,
               fm.isExecutableFile(atPath: "\(vdir)/\(latest)") {
                return "\(vdir)/\(latest)"
            }
        }
        return nil
    }
}

/// continuation 을 정확히 한 번만 resume 한다 (정상 종료와 타임아웃이 겹쳐도).
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<Shell.Result, Never>?
    init(_ c: CheckedContinuation<Shell.Result, Never>) { cont = c }
    func resume(_ r: Shell.Result) {
        let c: CheckedContinuation<Shell.Result, Never>? = lock.withLock { defer { cont = nil }; return cont }
        c?.resume(returning: r)
    }
}
