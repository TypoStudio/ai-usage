import AIUsageCore
import AppKit
import SwiftUI

struct DetailView: View {
    @EnvironmentObject private var model: UsageModel
    @EnvironmentObject private var focus: DetailFocus
    @AppStorage(Prefs.threshold) private var threshold = 90.0
    @State private var rawSheet: RawSheet?

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(ProviderKind.allCases) { p in
                            section(p).id(p)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: focus.provider) { _, p in
                    if let p { withAnimation { proxy.scrollTo(p, anchor: .top) } }
                }
                .onAppear { if let p = focus.provider { proxy.scrollTo(p, anchor: .top) } }
            }
            Divider()
            footer
        }
        .frame(minWidth: 600, minHeight: 360)
        .sheet(item: $rawSheet) { s in RawResponseView(sheet: s) }
    }

    @ViewBuilder
    private func section(_ p: ProviderKind) -> some View {
        let configs = model.enabledAccounts.filter { $0.provider == p }
        VStack(alignment: .leading, spacing: 8) {
            Text(p.title).font(.headline)
            if configs.isEmpty {
                Text("켜진 계정이 없습니다. 설정에서 계정을 켜세요.").foregroundStyle(.secondary).font(.callout)
            }
            ForEach(configs) { c in
                AccountCard(usage: model.usage(for: c), threshold: threshold)
                    .contextMenu {
                        Button("터미널 명령 복사") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(AccountCommand.command(for: model.usage(for: c)), forType: .string)
                        }
                        Button("응답 보기") {
                            rawSheet = RawSheet(id: c.id, title: c.label, text: model.rawResponses[c.id] ?? String(localized: "아직 받은 응답이 없습니다."))
                        }
                        Divider()
                        Button("이 계정 숨기기") { model.hide(c.id) }
                    }
            }
        }
    }

    private var footer: some View {
        HStack {
            if let e = model.snapshotError {
                Label("스냅샷 저장 실패: \(e)", systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.caption)
            } else if let d = model.lastUpdated {
                Text("마지막 갱신 \(d.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary).font(.callout)
            }
            Spacer()
            if model.isRefreshing { ProgressView().controlSize(.small) }
            Button("새로고침") { model.refresh() }.disabled(model.isRefreshing)
            SettingsLink { Text("설정…") }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

struct AccountCard: View {
    var usage: AccountUsage
    var threshold: Double

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            RingGaugeView(account: usage, warnThreshold: threshold)
                .frame(width: 64, height: 64)
                .padding(6)
                .background(Color.black, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(usage.label).font(.system(.body, design: .monospaced).weight(.semibold))
                    Text(usage.email ?? "").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if let plan = usage.plan { Text(plan).font(.caption).padding(.horizontal, 6).padding(.vertical, 1).background(.quaternary, in: Capsule()) }
                }
                statusLine
                // 만료·오류 상태의 한도 값은 지난 값이라 헷갈리므로 숨긴다
                if usage.status == .ok || usage.status == .refreshing {
                    ForEach(usage.limits, id: \.name) { l in limitRow(l) }
                }
            }
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var statusLine: some View {
        switch usage.status {
        case .refreshing:
            Label("갱신 중…", systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary)
        case .expired:
            VStack(alignment: .leading, spacing: 4) {
                Label(usage.error ?? String(localized: "토큰 만료"), systemImage: "key.slash").font(.caption).foregroundStyle(.orange)
                HStack {
                    // .textSelection 을 붙이면 macOS 27 에서 글자가 위아래로 뒤집혀 그려진다 → 복사 버튼만 둔다
                    Text(AccountCommand.command(for: usage)).font(.caption.monospaced())
                    Button("복사") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(AccountCommand.command(for: usage), forType: .string)
                    }.controlSize(.mini)
                }
            }
        case .error:
            Label(usage.error ?? "", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red).lineLimit(2)
        case .ok:
            if let e = usage.error { Label(e, systemImage: "clock.badge.exclamationmark").font(.caption).foregroundStyle(.orange) }
        }
        if let w = usage.warning {
            Label(w, systemImage: "exclamationmark.octagon.fill").font(.caption).foregroundStyle(.red)
        }
    }

    private func limitRow(_ l: Limit) -> some View {
        let color = l.ring.map { RingGaugeView.colors[$0.rawValue] } ?? .gray
        let flagged = l.percent >= threshold || l.severity != nil
        return HStack(spacing: 8) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(l.name).font(.caption.monospaced()).frame(width: 96, alignment: .leading)
            // ProgressView 는 비활성 창에서 회색이 된다 → 직접 그린다
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.18))
                    Capsule().fill(flagged ? RingGaugeView.alert : color)
                        .frame(width: max(4, g.size.width * min(l.percent, 100) / 100))
                }
            }
            .frame(height: 6)
            Text(UsageFormat.percent(l.percent)).font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
                .foregroundStyle(flagged ? RingGaugeView.alert : .primary)
            Text(UsageFormat.remaining(until: l.resetsAt)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
            // 정확한 리셋 일시 (시스템 언어·시간대 형식, 예: 9월 24일 (목) 오전 9:00)
            Text(l.resetsAt.map { $0.formatted(.dateTime.month().day().weekday(.abbreviated).hour().minute()) } ?? "-")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 150, alignment: .trailing)
                .help(l.resetsAt.map { $0.formatted(date: .complete, time: .standard) } ?? "")
        }
    }
}

struct RawSheet: Identifiable {
    var id: String
    var title: String
    var text: String
}

struct RawResponseView: View {
    var sheet: RawSheet
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading) {
            Text(sheet.title).font(.headline)
            ScrollView {
                Text(sheet.text).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("복사") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(sheet.text, forType: .string)
                }
                Button("닫기") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 520, height: 480)
    }
}
