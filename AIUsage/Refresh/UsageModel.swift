import AIUsageCore
import AIUsageFetch
import AppKit
import Foundation
import WidgetKit

/// 계정 목록·조회·스냅샷·위젯 리로드를 맡는다.
@MainActor
final class UsageModel: ObservableObject {
    static let shared = UsageModel()

    @Published var accounts: [AccountConfig] = []
    /// 상세 창·설정·스냅샷의 프로바이더 순서. 저장된 순서 뒤에 새로 생긴 프로바이더를 붙인다.
    @Published private(set) var providerOrder: [ProviderKind] = ProviderKind.allCases
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
    private var versions: AccountFetcher.Versions?

    /// `--demo`: README 스크린샷용 가짜 계정. 조회·스냅샷 쓰기·알림을 모두 건너뛴다.
    let isDemo = CommandLine.arguments.contains("--demo")

    private init() {
        Prefs.registerDefaults()
        let saved = (UserDefaults.standard.stringArray(forKey: Prefs.providerOrder) ?? []).compactMap(ProviderKind.init(rawValue:))
        providerOrder = saved + ProviderKind.allCases.filter { !saved.contains($0) }
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

    /// 켜진 계정을 프로바이더 순서대로 (같은 프로바이더 안에서는 설정 순서 유지)
    var enabledAccounts: [AccountConfig] {
        let rank = Dictionary(uniqueKeysWithValues: providerOrder.enumerated().map { ($1, $0) })
        return accounts.filter(\.enabled).enumerated()
            .sorted { (rank[$0.element.provider] ?? 9, $0.offset) < (rank[$1.element.provider] ?? 9, $1.offset) }
            .map(\.element)
    }

    /// 프로바이더 섹션을 위(-1)·아래(+1)로 한 칸 옮긴다
    func moveProvider(_ p: ProviderKind, by delta: Int) {
        guard let i = providerOrder.firstIndex(of: p), providerOrder.indices.contains(i + delta) else { return }
        providerOrder.swapAt(i, i + delta)
        UserDefaults.standard.set(providerOrder.map(\.rawValue), forKey: Prefs.providerOrder)
        if !isDemo { writeSnapshot(force: true) }
    }

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
        guard versions == nil else { return }
        let d = UserDefaults.standard
        versions = await AccountFetcher.versions(claudePath: d.string(forKey: Prefs.claudePath), codexPath: d.string(forKey: Prefs.codexPath),
                                                 agyPath: d.string(forKey: Prefs.agyPath))
    }

    private func refreshAccount(_ config: AccountConfig) async {
        if let b = backoff[config.id], b.until > Date() { return }
        apply(await AccountFetcher.fetch(provider: config.provider, dir: config.id, versions: versions ?? .init()), to: config)
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
