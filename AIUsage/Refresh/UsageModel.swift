import AIUsageCore
import AppKit
import Foundation
import WidgetKit

/// 계정 목록·조회·스냅샷·위젯 리로드를 맡는다.
@MainActor
final class UsageModel: ObservableObject {
    static let shared = UsageModel()

    @Published var accounts: [AccountConfig] = []
    @Published private(set) var usages: [String: AccountUsage] = [:]
    @Published private(set) var rawResponses: [String: String] = [:]
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isRefreshing = false
    @Published var snapshotError: String?

    private var timer: Timer?
    /// 429 백오프: 계정별 다음 허용 시각과 현재 지연
    private var backoff: [String: (until: Date, delay: TimeInterval)] = [:]
    private var lastDoctor: [String: Date] = [:]
    /// `claude doctor` 는 계정이 여러 개라도 한 번에 하나씩만 돌린다
    private var doctorChain: Task<Void, Never>?
    /// 화면이 꺼져 있거나 잠자기 중이면 갱신하지 않는다. 다크웨이크(화면 꺼진 채 잠깐 깨는 것) 중에
    /// 토큰 갱신이 돌다가 잠자기로 끊기면 로그인이 풀린다 (2026-09-24 cld2·cld3 사례).
    private var screensAsleep = false
    private var lastWidgetReload = Date.distantPast
    private var lastWidgetPayload: Data?
    private var claudeVersion: String?
    private var codexVersion: String?

    /// `--demo`: README 스크린샷용 가짜 계정. 조회·스냅샷 쓰기·알림을 모두 건너뛴다.
    let isDemo = CommandLine.arguments.contains("--demo")

    private init() {
        Prefs.registerDefaults()
        if isDemo {
            (accounts, usages) = DemoData.make()
            lastUpdated = Date()
            return
        }
        accounts = AccountStore.merge(AccountStore.load(), discovered: AccountDiscovery.discover())
        AccountStore.save(accounts)
        // 이전 스냅샷으로 먼저 채워 둔다
        for u in SnapshotStore.load().accounts { usages[u.id] = u }
    }

    var enabledAccounts: [AccountConfig] { accounts.filter(\.enabled) }

    func usage(for config: AccountConfig) -> AccountUsage {
        var u = usages[config.id] ?? AccountUsage(id: config.id, provider: config.provider, label: config.label, status: .refreshing)
        u.label = config.label
        return u
    }

    // MARK: 계정 편집

    func updateAccounts(_ new: [AccountConfig]) {
        accounts = new
        if isDemo { return }
        AccountStore.save(new)
        writeSnapshot(force: true)
    }

    func rediscover() {
        updateAccounts(AccountStore.merge(accounts, discovered: AccountDiscovery.discover()))
    }

    func addManual(path: String) {
        let isClaude = FileManager.default.fileExists(atPath: "\(path)/.claude.json")
        let isCodex = FileManager.default.fileExists(atPath: "\(path)/auth.json")
        guard isClaude || isCodex, !accounts.contains(where: { $0.id == path }) else { return }
        let p: ProviderKind = isClaude ? .claude : .codex
        updateAccounts(accounts + [AccountConfig(id: path, provider: p,
                                                 label: AccountDiscovery.defaultLabel(provider: p, path: path),
                                                 enabled: true, manual: true)])
        refresh()
    }

    func hide(_ id: String) {
        updateAccounts(accounts.map { var a = $0; if a.id == id { a.enabled = false }; return a })
    }

    // MARK: 주기 갱신

    func start() {
        guard !isDemo else { return }
        scheduleTimer()
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in UsageModel.shared.screensAsleep = true }
            }
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in
                    UsageModel.shared.screensAsleep = false
                    UsageModel.shared.refresh()
                }
            }
        }
        refresh()
    }

    func scheduleTimer() {
        timer?.invalidate()
        let minutes = max(1, UserDefaults.standard.integer(forKey: Prefs.refreshMinutes))
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: true) { _ in
            Task { @MainActor in UsageModel.shared.refresh() }
        }
    }

    /// 창을 열 때: 30초 안에 갱신했으면 건너뛴다
    func refreshIfStale() {
        if let lastUpdated, Date().timeIntervalSince(lastUpdated) < 30 { return }
        refresh()
    }

    func refresh() {
        guard !isRefreshing, !isDemo, !screensAsleep else { return }
        isRefreshing = true
        let targets = enabledAccounts
        Task {
            await resolveVersions()
            await withTaskGroup(of: Void.self) { group in
                for config in targets { group.addTask { await self.refreshAccount(config) } }
            }
            lastUpdated = Date()
            isRefreshing = false
            writeSnapshot(force: false)
            Notifier.evaluate(enabledAccounts.map(usage(for:)))
        }
    }

    private func resolveVersions() async {
        let d = UserDefaults.standard
        if claudeVersion == nil {
            claudeVersion = await ClaudeFetcher.version(claudePath: Shell.locate("claude", override: d.string(forKey: Prefs.claudePath)))
        }
        if codexVersion == nil {
            codexVersion = await CodexFetcher.version(codexPath: Shell.locate("codex", override: d.string(forKey: Prefs.codexPath)))
        }
    }

    private func refreshAccount(_ config: AccountConfig) async {
        if let b = backoff[config.id], b.until > Date() { return }
        let outcome: FetchOutcome
        switch config.provider {
        case .claude: outcome = await fetchClaude(config)
        case .codex: outcome = await CodexFetcher.fetch(dir: config.id, version: codexVersion ?? "0.100.0")
        }
        apply(outcome, to: config)
    }

    private func fetchClaude(_ config: AccountConfig) async -> FetchOutcome {
        let email = ClaudeFetcher.email(dir: config.id)
        guard var cred = await ClaudeFetcher.readCredential(dir: config.id) else {
            return .failed(String(localized: "자격 증명 없음"), email: email, raw: nil)
        }
        if cred.expiresAt < Date() {
            // 갱신 토큰이 없으면 doctor 로도 못 살린다 — 괜히 돌리지 않는다
            guard cred.canRefresh else { return .expired(Self.loginRequired, email: email, raw: nil) }
            // claude doctor 는 계정당 10분에 1회까지
            if let last = lastDoctor[config.id], Date().timeIntervalSince(last) < 600 {
                return .expired(String(localized: "토큰 만료 — 자동 갱신 실패"), email: email, raw: nil)
            }
            guard let claude = Shell.locate("claude", override: UserDefaults.standard.string(forKey: Prefs.claudePath)) else {
                return .expired(String(localized: "토큰 만료 — claude 실행 파일을 찾지 못함"), email: email, raw: nil)
            }
            var u = usage(for: config); u.status = .refreshing; usages[config.id] = u
            guard await runDoctorSerially(dir: config.id, claudePath: claude) else { return .skipped }
            guard let fresh = await ClaudeFetcher.readCredential(dir: config.id), fresh.canRefresh else {
                return .expired(Self.loginRequired, email: email, raw: nil)
            }
            guard fresh.expiresAt > Date() else {
                return .expired(String(localized: "토큰 만료 — 자동 갱신 실패"), email: email, raw: nil)
            }
            cred = fresh
        }
        return await ClaudeFetcher.fetch(token: cred.token, subscription: cred.subscription, email: email,
                                         version: claudeVersion ?? "2.0.0")
    }

    static let loginRequired = String(localized: "로그인이 풀렸습니다 — 아래 명령으로 Claude Code 를 열고 /login 하세요")

    /// 앞선 doctor 가 끝난 뒤에 실행한다. 차례가 왔을 때 화면이 꺼졌으면 건너뛰고 false.
    private func runDoctorSerially(dir: String, claudePath: String) async -> Bool {
        let previous = doctorChain
        let mine = Task { @MainActor [weak self] () -> Bool in
            await previous?.value
            guard let self, !self.screensAsleep else { return false }
            self.lastDoctor[dir] = Date()
            await ClaudeFetcher.runDoctor(dir: dir, claudePath: claudePath)
            return true
        }
        doctorChain = Task { _ = await mine.value }
        return await mine.value
    }

    private func apply(_ outcome: FetchOutcome, to config: AccountConfig) {
        if case .skipped = outcome { return }
        var u = usage(for: config)
        let now = Date()
        switch outcome {
        case let .ok(parsed, email, raw):
            u.email = email ?? u.email
            u.plan = parsed.plan; u.warning = parsed.warning; u.workspaceID = parsed.workspaceID
            u.limits = parsed.limits; u.status = .ok; u.error = nil; u.fetchedAt = now
            rawResponses[config.id] = prettyJSON(raw)
            backoff[config.id] = nil
        case let .expired(msg, email, raw):
            u.email = email ?? u.email; u.status = .expired; u.error = msg
            if let raw { rawResponses[config.id] = prettyJSON(raw) }
        case let .rateLimited(email):
            // 이전 값은 그대로 두고 지수 백오프 (최대 30분)
            let interval = TimeInterval(max(1, UserDefaults.standard.integer(forKey: Prefs.refreshMinutes)) * 60)
            let delay = min(1800, (backoff[config.id]?.delay ?? interval / 2) * 2)
            backoff[config.id] = (now.addingTimeInterval(delay), delay)
            u.email = email ?? u.email
            if u.fetchedAt == nil { u.status = .error }
            u.error = String(localized: "요청 제한(429) — \(Int(delay / 60))분 후 재시도")
        case .skipped:
            return
        case let .failed(msg, email, raw):
            u.email = email ?? u.email; u.status = .error; u.error = msg
            if let raw { rawResponses[config.id] = prettyJSON(raw) }
        }
        usages[config.id] = u
    }

    private func prettyJSON(_ data: Data) -> String {
        guard let o = try? JSONSerialization.jsonObject(with: data),
              let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) else {
            return String(decoding: data, as: UTF8.self)
        }
        return String(decoding: d, as: UTF8.self)
    }

    // MARK: 스냅샷 · 위젯

    /// 임계치·갱신 주기가 바뀌면 위젯도 바로 반영
    func thresholdChanged() { writeSnapshot(force: true) }

    /// 스냅샷은 항상 쓰고, 위젯 리로드는 값이 바뀌었거나 5분이 지났을 때만 (시스템 리로드 예산 절약,
    /// 동시에 위젯의 `앱 실행 필요` 판정이 앱이 살아 있는데도 뜨지 않게).
    private func writeSnapshot(force: Bool) {
        guard !isDemo else { return }
        let snapshot = Snapshot(updatedAt: lastUpdated ?? Date(), accounts: enabledAccounts.map(usage(for:)),
                                threshold: UserDefaults.standard.double(forKey: Prefs.threshold),
                                refreshInterval: TimeInterval(max(1, UserDefaults.standard.integer(forKey: Prefs.refreshMinutes)) * 60))
        do {
            try SnapshotStore.save(snapshot)
            snapshotError = nil
        } catch {
            snapshotError = error.localizedDescription
        }
        var comparable = snapshot
        comparable.updatedAt = .distantPast
        let payload = try? JSONEncoder().encode(comparable)
        if force || payload != lastWidgetPayload || Date().timeIntervalSince(lastWidgetReload) >= 300 {
            lastWidgetPayload = payload
            lastWidgetReload = Date()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
