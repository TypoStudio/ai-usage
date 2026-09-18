import AIUsageCore
import SwiftUI
import WidgetKit

@main
struct AIUsageWidgetBundle: WidgetBundle {
    var body: some Widget {
        ClaudeUsageWidget()
        CodexUsageWidget()
    }
}

struct ClaudeUsageWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "ClaudeUsageWidget", intent: ClaudeAccountIntent.self,
                               provider: UsageTimelineProvider<ClaudeAccountIntent>()) { UsageWidgetView(entry: $0) }
            .configurationDisplayName("Claude Code 사용량")
            .description("계정마다 링 게이지 하나. 바깥 5시간, 가운데 주간, 안쪽 주간 Fable.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
            .contentMarginsDisabled()
    }
}

struct CodexUsageWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "CodexUsageWidget", intent: CodexAccountIntent.self,
                               provider: UsageTimelineProvider<CodexAccountIntent>()) { UsageWidgetView(entry: $0) }
            .configurationDisplayName("Codex 사용량")
            .description("계정마다 링 게이지 하나. 바깥 5시간, 가운데 7일.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
            .contentMarginsDisabled()
    }
}

struct UsageWidgetView: View {
    var entry: UsageEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .padding(14)
            .foregroundStyle(.white)
            .containerBackground(Color.black, for: .widget)
            .widgetURL(URL(string: "aiusage://open?provider=\(entry.provider.rawValue)"))
    }

    @ViewBuilder
    private var content: some View {
        if entry.accounts.isEmpty {
            VStack(spacing: 6) {
                header
                Spacer()
                Text("앱을 실행해 계정을 확인하세요").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Spacer()
            }
        } else {
            switch family {
            case .systemSmall: small
            case .systemLarge: large
            default: medium
            }
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text(entry.provider.title).font(.caption.weight(.semibold))
            Spacer(minLength: 4)
            if entry.isStale {
                Text("앱 실행 필요").font(.caption2.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(RingGaugeView.alert, in: Capsule())
            } else {
                Text(entry.snapshot.updatedAt, style: .time).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var small: some View {
        let a = entry.selectedAccount
        return VStack(spacing: 6) {
            header
            RingGaugeView(account: a, warnThreshold: entry.snapshot.warnThreshold)
            caption(a)
        }
    }

    /// 게이지 아래: 라벨 + 가장 높은 사용률
    private func caption(_ a: AccountUsage?) -> some View {
        HStack(spacing: 4) {
            Text(a?.label ?? "").foregroundStyle(.secondary)
            if let a, a.status == .ok {
                Text(UsageFormat.percent(a.maxPercent))
                    .foregroundStyle(a.maxPercent >= entry.snapshot.warnThreshold || a.warning != nil ? RingGaugeView.alert : .white)
            }
        }
        .font(.caption2.monospaced())
        .lineLimit(1)
    }

    private var medium: some View {
        VStack(spacing: 8) {
            header
            HStack(spacing: 10) {
                ForEach(Array(entry.accounts.prefix(3))) { a in
                    VStack(spacing: 4) {
                        RingGaugeView(account: a, warnThreshold: entry.snapshot.warnThreshold)
                        caption(a)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ForEach(Array(entry.accounts.prefix(3))) { a in
                HStack(spacing: 12) {
                    RingGaugeView(account: a, warnThreshold: entry.snapshot.warnThreshold).frame(width: 92, height: 92)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(a.label).font(.caption.monospaced().weight(.semibold))
                            Text(a.email ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        if a.status == .ok {
                            ForEach(a.limits.filter { $0.ring != nil }, id: \.name) { l in
                                HStack(spacing: 6) {
                                    Circle().fill(RingGaugeView.colors[l.ring!.rawValue]).frame(width: 6, height: 6)
                                    Text(l.name).font(.caption2.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
                                    Text(UsageFormat.percent(l.percent)).font(.caption2.monospacedDigit())
                                    Text(UsageFormat.remaining(until: l.resetsAt, now: entry.date)).font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
                                }
                            }
                            if let w = a.warning { Text(w).font(.caption2).foregroundStyle(RingGaugeView.alert).lineLimit(1) }
                        } else {
                            Text(a.error ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}
