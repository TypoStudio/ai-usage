import AIUsageCore
import AppKit
import ServiceManagement
import SwiftUI

@main
struct AIUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            SettingsView().environmentObject(UsageModel.shared)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("업데이트 확인…") { AppDelegate.checkForUpdates(manual: true) }
            }
        }
    }
}

/// 상세 창은 AppKit 이 직접 관리한다 — 창이 닫혀 있어도 위젯 링크·Dock 클릭으로 다시 연다.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let focus = DetailFocus()

    /// URL(`aiusage://`)은 Apple Event 로 직접 받는다. SwiftUI 수명 주기에 맡기면 이미 떠 있는 앱에서
    /// 창이 없을 때 이벤트가 `application(_:open:)` 까지 오지 않는 경우가 있다.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleGetURL(_:withReplyEvent:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: s) else { return }
        open(url)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Notifier.requestAuthorization()
        if !UsageModel.shared.isDemo { enableLaunchAtLoginOnce() }
        UsageModel.shared.start()
        // 로그인 시 자동 실행(백그라운드)일 때는 창을 띄우지 않는다
        let event = NSAppleEventManager.shared().currentAppleEvent
        let launchedAsLoginItem = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        // `--background`: 로그인 시 자동 실행과 같은 상태(창 없음)로 띄운다 — 테스트용
        if !launchedAsLoginItem, !CommandLine.arguments.contains("--background") { showDetail(provider: nil) }
        if UpdateService.autoCheckEnabled, !UsageModel.shared.isDemo { Self.checkForUpdates(manual: false) }
    }

    static func checkForUpdates(manual: Bool) {
        Task { @MainActor in
            if let info = await UpdateService.checkForUpdate() {
                showUpdateAlert(info: info)
            } else if manual {
                showUpToDateAlert()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDetail(provider: nil)
        return false
    }

    /// `aiusage://open?provider=claude`
    private func open(_ url: URL) {
        guard url.scheme == "aiusage" else { return }
        let item = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "provider" }
        showDetail(provider: item?.value.flatMap(ProviderKind.init(rawValue:)))
    }

    func showDetail(provider: ProviderKind?) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "AI Usage"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: DetailView().environmentObject(UsageModel.shared).environmentObject(focus))
            w.setFrameAutosaveName("DetailWindow")
            if !w.setFrameUsingName("DetailWindow") { w.center() }
            window = w
        }
        focus.provider = provider
        // 백그라운드 앱의 활성화 요청은 거절될 수 있다 → 활성화와 별개로 창은 항상 앞으로
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        UsageModel.shared.refreshIfStale()
    }

    /// 기획: 로그인 시 실행 기본 on — 안 켜면 위젯 값이 멈춘다
    private func enableLaunchAtLoginOnce() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: Prefs.launchAtLoginInitialized) else { return }
        d.set(true, forKey: Prefs.launchAtLoginInitialized)
        try? SMAppService.mainApp.register()
    }
}

/// 위젯에서 열었을 때 스크롤할 프로바이더
@MainActor
final class DetailFocus: ObservableObject {
    @Published var provider: ProviderKind?
}
