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
    /// 화면이 꺼져 있거나 잠자기 중이면 갱신하지 않는다. 다크웨이크(화면 꺼진 채 잠깐 깨는 것) 중에
    /// 토큰 갱신이 돌다가 잠자기로 끊기면 서버는 갱신 토큰을 교체했는데 우리는 저장을 못 해 로그인이 풀린다.
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
        let version = claudeVersion ?? "2.0.0"
        let cred = await ClaudeFetcher.readCredential(dir: config.id)
        // 1) 앱 자체 로그인이 있으면 그 토큰으로 — 만료 5분 전에 미리 갱신하고, 401 이면 한 번 갱신해 다시 시도
        if var token = await ClaudeOAuth.load(dir: config.id) {
            var refreshed = false
            if token.needsRefresh {
                var u = usage(for: config); u.status = .refreshing; usages[config.id] = u
                switch await refreshAppToken(token, dir: config.id, email: email) {
                case let .success(t): token = t; refreshed = true
                case let .failure(f): return f.outcome
                }
            }
            let outcome = await ClaudeFetcher.fetch(token: token.accessToken, subscription: cred?.subscription,
                                                    email: token.email ?? email, version: version)
            guard case .expired = outcome, !refreshed else { return outcome }
            switch await refreshAppToken(token, dir: config.id, email: email) {
            case let .success(t):
                return await ClaudeFetcher.fetch(token: t.accessToken, subscription: cred?.subscription,
                                                 email: t.email ?? email, version: version)
            case let .failure(f): return f.outcome
            }
        }
        // 2) 없으면 Claude Code 의 자격 증명을 읽기만 한다. 만료됐으면 앱에서 로그인하라고 안내한다 —
        //    여기서 `claude doctor` 로 갱신하면 Claude Code 와 갱신 토큰을 두고 경쟁해 로그인이 풀린다.
        guard let cred, cred.expiresAt > Date() else { return .expired(Self.loginRequired, email: email, raw: nil) }
        return await ClaudeFetcher.fetch(token: cred.token, subscription: cred.subscription, email: email, version: version)
    }

    static let loginRequired = String(localized: "로그인이 필요합니다 — ‘로그인’ 을 누르면 이후 앱이 스스로 갱신합니다")

    private struct RefreshFailure: Error { var outcome: FetchOutcome }

    /// 갱신 실패 시 토큰은 지우지 않는다. 429 는 백오프, invalid_grant 만 재로그인.
    private func refreshAppToken(_ token: ClaudeOAuth.Token, dir: String, email: String?) async -> Result<ClaudeOAuth.Token, RefreshFailure> {
        do {
            return .success(try await ClaudeOAuth.refresh(token, dir: dir))
        } catch ClaudeOAuth.Failure.invalidGrant {
            return .failure(RefreshFailure(outcome: .expired(Self.loginRequired, email: email, raw: nil)))
        } catch ClaudeOAuth.Failure.http(429, _) {
            return .failure(RefreshFailure(outcome: .rateLimited(email: email)))
        } catch {
            return .failure(RefreshFailure(outcome: .failed(String(localized: "토큰 갱신 실패 — \(String(describing: error))"), email: email, raw: nil)))
        }
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
