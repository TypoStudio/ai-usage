import AIUsageCore
import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            AccountsTab().tabItem { Label("계정", systemImage: "person.2") }
            RefreshTab().tabItem { Label("갱신", systemImage: "arrow.clockwise") }
            AlertsTab().tabItem { Label("알림", systemImage: "bell") }
            GeneralTab().tabItem { Label("일반", systemImage: "gearshape") }
            AboutTab().tabItem { Label("정보", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 440)
    }
}

private struct AccountsTab: View {
    @EnvironmentObject private var model: UsageModel

    var body: some View {
        VStack(alignment: .leading) {
            Text("순서가 위젯의 게이지 순서입니다. 드래그해서 바꾸세요. medium 위젯에는 앞의 3개가 들어갑니다.")
                .font(.callout).foregroundStyle(.secondary)
            List {
                ForEach(ProviderKind.allCases) { p in
                    Section(p.title) {
                        ForEach(model.accounts.filter { $0.provider == p }) { a in row(a) }
                            .onMove { from, to in move(provider: p, from: from, to: to) }
                    }
                }
            }
            HStack {
                Button("경로 추가…") { addPath() }
                Button("다시 탐지") { model.rediscover() }
                Spacer()
                Button("지금 새로고침") { model.refresh() }
            }
        }
        .padding()
    }

    private func row(_ a: AccountConfig) -> some View {
        HStack {
            Toggle("", isOn: binding(a.id, \.enabled)).labelsHidden()
            TextField("라벨", text: binding(a.id, \.label)).frame(width: 90)
            VStack(alignment: .leading, spacing: 1) {
                Text(a.id.replacingOccurrences(of: Shell.home, with: "~")).font(.caption.monospaced())
                let u = model.usage(for: a)
                Text(u.email ?? (u.error ?? "")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if a.manual {
                Button { model.updateAccounts(model.accounts.filter { $0.id != a.id }) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
            }
        }
    }

    private func binding<T>(_ id: String, _ key: WritableKeyPath<AccountConfig, T>) -> Binding<T> {
        Binding(
            get: { model.accounts.first { $0.id == id }![keyPath: key] },
            set: { v in model.updateAccounts(model.accounts.map { var a = $0; if a.id == id { a[keyPath: key] = v }; return a }) }
        )
    }

    /// 섹션 안의 인덱스를 전체 배열로 옮겨 적용
    private func move(provider: ProviderKind, from: IndexSet, to: Int) {
        var group = model.accounts.filter { $0.provider == provider }
        group.move(fromOffsets: from, toOffset: to)
        var it = group.makeIterator()
        model.updateAccounts(model.accounts.map { $0.provider == provider ? it.next()! : $0 })
    }

    private func addPath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.message = String(localized: ".claude.json 또는 auth.json 이 있는 설정 디렉토리를 고르세요.")
        if panel.runModal() == .OK, let url = panel.url { model.addManual(path: url.path) }
    }
}

private struct RefreshTab: View {
    @AppStorage(Prefs.refreshMinutes) private var minutes = 2

    var body: some View {
        Form {
            Picker("갱신 주기", selection: $minutes) {
                ForEach([1, 2, 5, 10], id: \.self) { Text("\($0)분").tag($0) }
            }
            .onChange(of: minutes) {
                UsageModel.shared.scheduleTimer()
                UsageModel.shared.thresholdChanged()
            }
            Text("위젯은 앱이 쓴 값을 보여 줄 뿐입니다. 앱이 꺼져 있으면 위젯 값이 멈춥니다.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct AlertsTab: View {
    @AppStorage(Prefs.threshold) private var threshold = 90.0
    @AppStorage(Prefs.notifyCredits) private var credits = true
    @AppStorage(Prefs.notifyRefreshFailure) private var refreshFailure = true

    var body: some View {
        Form {
            Stepper(value: $threshold, in: 50...100, step: 5) {
                Text("임계치 \(Int(threshold))%")
            }
            .onChange(of: threshold) { UsageModel.shared.thresholdChanged() }
            Text("한도가 임계치를 넘는 순간 한 번 알리고, 리셋된 뒤 다시 알립니다. 링도 이 값부터 빨갛게 바뀝니다.")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("크레딧 고갈 알림", isOn: $credits)
            Toggle("토큰 갱신 실패 알림", isOn: $refreshFailure)
        }
        .formStyle(.grouped)
    }
}

private struct GeneralTab: View {
    @AppStorage(Prefs.claudePath) private var claudePath = ""
    @AppStorage(Prefs.codexPath) private var codexPath = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var autoCheckUpdates = UpdateService.autoCheckEnabled

    var body: some View {
        Form {
            Toggle("로그인 시 실행", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    do { try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() } catch {}
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }
            Toggle("업데이트 자동 확인", isOn: Binding(
                get: { autoCheckUpdates },
                set: { autoCheckUpdates = $0; UpdateService.autoCheckEnabled = $0 }
            ))
            TextField("claude 경로", text: $claudePath, prompt: Text(Shell.locate("claude", override: nil) ?? String(localized: "자동 탐색")))
            TextField("codex 경로", text: $codexPath, prompt: Text(Shell.locate("codex", override: nil) ?? String(localized: "자동 탐색")))
            LabeledContent("스냅샷 파일") {
                Button("Finder에서 보기") {
                    if let url = SnapshotStore.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AboutTab: View {
    private let githubURL = URL(string: "https://github.com/TypoStudio/ai-usage")!
    private let bmcURL = URL(string: "https://www.buymeacoffee.com/typ0s2d10")!

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI Usage").font(.headline)
                    Text(versionText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("업데이트 확인…") { AppDelegate.checkForUpdates(manual: true) }
            }
            Text("© 2026 TypoStudio").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            HStack(spacing: 12) {
                imageLink("github", url: githubURL)
                imageLink("bmc_button", url: bmcURL)
            }
            Spacer()
        }
        .padding(24)
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return String(localized: "버전 \(v) (\(b))")
    }

    private func imageLink(_ name: String, url: URL) -> some View {
        Button { NSWorkspace.shared.open(url) } label: {
            if let image = NSImage(named: name) {
                Image(nsImage: image).resizable().scaledToFit().frame(height: 34)
            } else {
                Text(url.host ?? name)
            }
        }
        .buttonStyle(.plain)
        .help(url.absoluteString)
        .onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }
    }
}
