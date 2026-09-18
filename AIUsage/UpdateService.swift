import AppKit
import Foundation

// focus-play 의 UpdateService 를 옮겨온 것. GitHub 최신 릴리즈를 확인하고,
// DMG 를 받아 앱을 교체한 뒤 재실행한다.

struct UpdateInfo: Sendable {
    let version: String
    let htmlURL: URL
    let dmgURL: URL?
}

enum UpdateService {
    private static let autoCheckKey = "autoCheckForUpdates"

    /// 실행 시 자동으로 업데이트를 확인할지 (기본 true).
    static var autoCheckEnabled: Bool {
        get { UserDefaults.standard.object(forKey: autoCheckKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoCheckKey) }
    }

    private struct GitHubRelease: Codable {
        let tagName: String
        let htmlUrl: String
        let assets: [GitHubAsset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlUrl = "html_url"
            case assets
        }
    }

    private struct GitHubAsset: Codable {
        let name: String
        let browserDownloadUrl: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadUrl = "browser_download_url"
        }
    }

    static func checkForUpdate() async -> UpdateInfo? {
        guard let url = URL(string: "https://api.github.com/repos/TypoStudio/ai-usage/releases/latest") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            return nil
        }

        guard let release = try? JSONDecoder().decode(GitHubRelease.self, from: data),
              let htmlURL = URL(string: release.htmlUrl) else {
            return nil
        }

        let remoteVersion = release.tagName.hasPrefix("v")
            ? String(release.tagName.dropFirst())
            : release.tagName

        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"

        guard isNewer(remote: remoteVersion, current: currentVersion) else {
            return nil
        }

        let dmgURL = release.assets
            .first { $0.name.hasSuffix(".dmg") }
            .flatMap { URL(string: $0.browserDownloadUrl) }

        return UpdateInfo(version: remoteVersion, htmlURL: htmlURL, dmgURL: dmgURL)
    }

    /// DMG 다운로드(진행률) → 마운트 → 앱 교체 → 재실행. 실패 시 throw.
    static func performUpdate(dmgURL: URL, progressHandler: @escaping @MainActor (Double) -> Void) async throws {
        // .app 번들로 실행 중일 때만 교체한다. (swift run 등 개발 실행에서 빌드 폴더를 지우지 않도록)
        let currentAppPath = Bundle.main.bundlePath
        guard currentAppPath.hasSuffix(".app") else { throw UpdateError.replaceFailed }

        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.typostudio.aiusage", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let dmgPath = cacheDir.appendingPathComponent("update.dmg")
        try? FileManager.default.removeItem(at: dmgPath)

        let downloadedURL = try await downloadWithProgress(from: dmgURL, progressHandler: progressHandler)
        try FileManager.default.moveItem(at: downloadedURL, to: dmgPath)

        let attrs = try FileManager.default.attributesOfItem(atPath: dmgPath.path)
        let fileSize = attrs[.size] as? Int ?? 0
        if fileSize < 1024 {
            throw UpdateError.downloadFailed
        }

        let mountPoint = try mountDMG(at: dmgPath.path)

        defer {
            unmountDMG(at: mountPoint)
            try? FileManager.default.removeItem(at: dmgPath)
        }

        let contents = try FileManager.default.contentsOfDirectory(atPath: mountPoint)
        guard let appName = contents.first(where: { $0.hasSuffix(".app") }) else {
            throw UpdateError.appNotFoundInDMG
        }

        let sourceApp = mountPoint + "/" + appName
        let parentDir = (currentAppPath as NSString).deletingLastPathComponent
        let destApp = parentDir + "/" + appName

        try run("/bin/rm", ["-rf", currentAppPath])
        try run("/bin/cp", ["-R", sourceApp, destApp])
        try? run("/usr/bin/xattr", ["-rd", "com.apple.quarantine", destApp])
        // 위젯 익스텐션·아이콘을 시스템이 새 번들에서 다시 읽게 한다
        try? run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", ["-f", "-R", destApp])

        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = [destApp]
        try open.run()

        await MainActor.run {
            NSApp.terminate(nil)
        }
    }

    // MARK: - Private

    private static func run(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.replaceFailed }
    }

    private static func downloadWithProgress(from url: URL, progressHandler: @escaping @MainActor (Double) -> Void) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let delegate = DownloadDelegate(
                progressHandler: progressHandler,
                completion: { result in
                    continuation.resume(with: result)
                }
            )
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            session.downloadTask(with: url).resume()
        }
    }

    private static func mountDMG(at path: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["attach", path, "-nobrowse", "-noverify", "-noautoopen", "-plist"]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        try process.run()

        // waitUntilExit 전에 읽어야 파이프 버퍼가 차서 멈추지 않는다.
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw UpdateError.mountFailedWithMessage(String(data: stderrData, encoding: .utf8) ?? "")
        }

        guard let plist = try? PropertyListSerialization.propertyList(from: stdoutData, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mountPoint = entities.compactMap({ $0["mount-point"] as? String }).first else {
            throw UpdateError.mountFailedWithMessage("No mount point found")
        }

        return mountPoint
    }

    private static func unmountDMG(at mountPoint: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", mountPoint, "-quiet"]
        try? process.run()
        process.waitUntilExit()
    }

    private static func isNewer(remote: String, current: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let c = current.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(r.count, c.count) {
            let rv = i < r.count ? r[i] : 0
            let cv = i < c.count ? c[i] : 0
            if rv > cv { return true }
            if rv < cv { return false }
        }
        return false
    }
}

// MARK: - Download Delegate

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progressHandler: @MainActor (Double) -> Void
    private let completion: (Result<URL, Error>) -> Void
    private var tempFileURL: URL?

    init(progressHandler: @escaping @MainActor (Double) -> Void, completion: @escaping (Result<URL, Error>) -> Void) {
        self.progressHandler = progressHandler
        self.completion = completion
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // 이 메서드가 끝나면 location 이 삭제되므로 임시 위치로 옮겨둔다.
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".dmg")
        do {
            try FileManager.default.moveItem(at: location, to: temp)
            tempFileURL = temp
        } catch {
            completion(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let handler = progressHandler
        Task { @MainActor in handler(progress) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            completion(.failure(error))
        } else if let tempFileURL {
            completion(.success(tempFileURL))
        } else {
            completion(.failure(UpdateError.downloadFailed))
        }
        session.invalidateAndCancel()
    }
}

// MARK: - Errors

enum UpdateError: LocalizedError {
    case appNotFoundInDMG
    case mountFailedWithMessage(String)
    case replaceFailed
    case downloadFailed

    var errorDescription: String? {
        switch self {
        case .appNotFoundInDMG: return "App not found in DMG"
        case .mountFailedWithMessage(let msg): return "Failed to mount DMG: \(msg)"
        case .replaceFailed: return "Failed to replace app"
        case .downloadFailed: return "Download failed"
        }
    }
}

// MARK: - Alerts

@MainActor
func showUpdateAlert(info: UpdateInfo) {
    NSApp.activate(ignoringOtherApps: true)

    let alert = NSAlert()
    alert.messageText = String(localized: "새 버전이 있습니다")
    alert.informativeText = String(localized: "AI Usage \(info.version) 을(를) 설치할 수 있습니다.")

    if info.dmgURL != nil {
        alert.addButton(withTitle: String(localized: "지금 설치"))
    }
    alert.addButton(withTitle: String(localized: "릴리즈 페이지 열기"))
    alert.addButton(withTitle: String(localized: "나중에"))
    alert.alertStyle = .informational

    let response = alert.runModal()

    if info.dmgURL != nil {
        switch response {
        case .alertFirstButtonReturn:
            performAutoUpdate(info: info)
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(info.htmlURL)
        default:
            break
        }
    } else if response == .alertFirstButtonReturn {
        NSWorkspace.shared.open(info.htmlURL)
    }
}

@MainActor
func showUpToDateAlert() {
    NSApp.activate(ignoringOtherApps: true)

    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    let alert = NSAlert()
    alert.messageText = String(localized: "최신 버전입니다")
    alert.informativeText = "AI Usage \(version)"
    alert.addButton(withTitle: String(localized: "확인"))
    alert.alertStyle = .informational
    alert.runModal()
}

@MainActor
private func performAutoUpdate(info: UpdateInfo) {
    guard let dmgURL = info.dmgURL else { return }

    let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 320, height: 130),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    panel.title = String(localized: "업데이트")
    panel.isReleasedWhenClosed = false
    panel.center()
    panel.level = .floating

    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 130))

    let label = NSTextField(labelWithString: String(localized: "\(info.version) 다운로드 중…"))
    label.frame = NSRect(x: 20, y: 80, width: 280, height: 20)
    label.alignment = .center
    contentView.addSubview(label)

    let percentLabel = NSTextField(labelWithString: "0%")
    percentLabel.frame = NSRect(x: 20, y: 55, width: 280, height: 20)
    percentLabel.alignment = .center
    percentLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    contentView.addSubview(percentLabel)

    let progressBar = NSProgressIndicator()
    progressBar.style = .bar
    progressBar.isIndeterminate = false
    progressBar.minValue = 0
    progressBar.maxValue = 1
    progressBar.doubleValue = 0
    progressBar.frame = NSRect(x: 20, y: 30, width: 280, height: 20)
    contentView.addSubview(progressBar)

    panel.contentView = contentView
    panel.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)

    Task {
        do {
            try await UpdateService.performUpdate(dmgURL: dmgURL) { progress in
                progressBar.doubleValue = progress
                percentLabel.stringValue = "\(Int(progress * 100))%"
                if progress >= 1.0 {
                    label.stringValue = String(localized: "\(info.version) 설치 중…")
                    percentLabel.isHidden = true
                    progressBar.isIndeterminate = true
                    progressBar.startAnimation(nil)
                }
            }
        } catch {
            panel.close()
            let errorAlert = NSAlert()
            errorAlert.messageText = String(localized: "업데이트 실패")
            errorAlert.informativeText = error.localizedDescription
            errorAlert.addButton(withTitle: String(localized: "직접 다운로드"))
            errorAlert.addButton(withTitle: String(localized: "확인"))
            errorAlert.alertStyle = .warning

            if errorAlert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(info.htmlURL)
            }
        }
    }
}
