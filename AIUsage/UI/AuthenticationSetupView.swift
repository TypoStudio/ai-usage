import AIUsageCore
import AppKit
import SwiftUI

/// 설정 › 계정 › `인증 환경 설정…`: 프로바이더와 계정 이름으로 설정 디렉토리를 만든다.
/// 미리보기 → 확인 → 백업 후 생성 → 결과(백업 위치·디렉토리·로그인 명령). 파일 작업은 백그라운드에서 돌고,
/// 적용 중에는 입력·닫기를 막아 두 번 적용되거나 갱신과 겹치지 않게 한다.
struct AuthenticationSetupView: View {
    @EnvironmentObject private var model: UsageModel
    @Environment(\.dismiss) private var dismiss

    @State private var provider = ProviderKind.claude
    @State private var names = AuthenticationSetupView.defaultNames(.claude)
    @State private var plan: AuthenticationSetupPlan?
    @State private var result: AuthenticationSetupResult?
    @State private var previewing = false
    @State private var applying = false
    @State private var confirming = false
    @State private var error: String?

    private static let providers: [ProviderKind] = [.claude, .codex]

    private var accounts: [String] {
        names.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private var busy: Bool { previewing || applying }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("인증 환경 설정").font(.headline)
            Text("계정 디렉토리와 공통 설정 링크를 만듭니다. 생성 전에 기존 설정을 백업합니다.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let result {
                        resultSection(result)
                    } else {
                        inputSection
                        if let plan { planSection(plan) }
                    }
                    if let error {
                        Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        .padding()
        .frame(width: 520, height: 400)
        .interactiveDismissDisabled(applying)
        .onChange(of: provider) { _, p in
            names = Self.defaultNames(p)
            plan = nil
            error = nil
        }
        .onChange(of: names) { plan = nil; error = nil }
        .alert("계정 디렉토리를 생성하시겠습니까?", isPresented: $confirming) {
            Button("생성") { apply() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("생성 전에 기존 설정을 백업합니다. 기존 파일은 삭제하지 않습니다.")
        }
    }

    // MARK: 입력

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("프로바이더") {
                Picker("프로바이더", selection: $provider) {
                    ForEach(Self.providers) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 260)
            }
            LabeledContent("계정 이름") {
                TextField("쉼표로 구분", text: $names).textFieldStyle(.roundedBorder)
            }
            Text("이름마다 설정 디렉토리를 하나씩 만듭니다. (~/.claude-<이름>, ~/.codex-<이름>)")
                .font(.caption).foregroundStyle(.secondary)
            if accounts.isEmpty {
                Text("계정 이름을 한 개 이상 입력하십시오.").font(.caption).foregroundStyle(.orange)
            }
        }
        .disabled(busy)
    }

    // MARK: 미리보기

    private func planSection(_ plan: AuthenticationSetupPlan) -> some View {
        GroupBox("변경 예정") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(plan.summary, id: \.self) {
                    Text(verbatim: $0).font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(plan.warnings, id: \.self) {
                    Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("생성 전에 기존 설정을 백업합니다. 기존 파일은 삭제하지 않습니다.")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: 결과

    private func resultSection(_ result: AuthenticationSetupResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("계정 목록에 추가했습니다.", systemImage: "checkmark.circle").foregroundStyle(.green)
            if !result.backupPath.isEmpty {
                GroupBox("백업 위치") {
                    HStack {
                        Text(verbatim: result.backupPath).font(.caption.monospaced()).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Finder에서 보기") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: result.backupPath)])
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            GroupBox("생성된 계정 디렉토리") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(result.accountPaths, id: \.self) {
                        Text(verbatim: $0).font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !result.loginCommands.isEmpty {
                GroupBox("로그인 명령") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(result.loginCommands, id: \.self) { cmd in
                            HStack {
                                Text(verbatim: cmd).font(.caption.monospaced()).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer()
                                Button("복사") { copy(cmd) }.buttonStyle(.borderless)
                            }
                        }
                        HStack {
                            Text("위 명령으로 각 디렉토리에 한 번씩 로그인하십시오. 로그인하기 전에는 사용량을 가져올 수 없습니다.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button("모두 복사") { copy(result.loginCommands.joined(separator: "\n")) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            ForEach(result.warnings, id: \.self) {
                Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: 하단 버튼

    private var footer: some View {
        HStack {
            if busy {
                ProgressView().controlSize(.small)
                if applying {
                    Text("적용 중…").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("미리보기 중…").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if result == nil {
                if plan == nil {
                    Button("미리보기") { preview() }
                        .keyboardShortcut(.defaultAction).disabled(busy || accounts.isEmpty)
                } else {
                    Button("생성…") { confirming = true }
                        .keyboardShortcut(.defaultAction).disabled(busy)
                }
            }
            Button("닫기") { dismiss() }
                .keyboardShortcut(.cancelAction).disabled(applying)
        }
    }

    // MARK: 동작 — 파일 작업은 Task.detached 로 메인 액터 밖에서 돈다

    private func preview() {
        guard !busy, !accounts.isEmpty else { return }
        previewing = true
        error = nil
        let setup = AuthenticationSetup(), p = provider, list = accounts
        Task {
            do {
                plan = try await Task.detached { try setup.preview(provider: p, accounts: list) }.value
            } catch {
                self.error = error.localizedDescription
            }
            previewing = false
        }
    }

    private func apply() {
        guard let plan, !applying, result == nil else { return }
        applying = true
        error = nil
        let setup = AuthenticationSetup()
        Task {
            await runApply(plan, setup: setup)
            applying = false
        }
    }

    /// 갱신과 겹치지 않도록 적용 구간 동안 갱신을 멈춘다. 실패하면 디스크 상태가 바뀌었을 수 있으니 계획을 버리고 다시 미리보기부터 하게 한다.
    private func runApply(_ plan: AuthenticationSetupPlan, setup: AuthenticationSetup) async {
        await model.beginAuthenticationSetup()
        defer { model.endAuthenticationSetup() }
        do {
            let r = try await Task.detached { try setup.apply(plan) }.value
            model.registerSetupAccounts(paths: r.accountPaths, provider: plan.provider)
            result = r
        } catch {
            self.error = error.localizedDescription
            self.plan = nil
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func defaultNames(_ p: ProviderKind) -> String {
        p == .codex ? "one, two, three, personal" : "one, two, three, team, personal"
    }
}
