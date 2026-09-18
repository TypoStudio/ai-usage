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

    func applicationDidFinishLaunching(_ notification: Notification) {
        Notifier.requestAuthorization()
        if !UsageModel.shared.isDemo { enableLaunchAtLoginOnce() }
        UsageModel.shared.start()
        // 로그인 시 자동 실행(백그라운드)일 때는 창을 띄우지 않는다
        let event = NSAppleEventManager.shared().currentAppleEvent
        let launchedAsLoginItem = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if !launchedAsLoginItem { showDetail(provider: nil) }
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
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first, url.scheme == "aiusage" else { return }
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
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
