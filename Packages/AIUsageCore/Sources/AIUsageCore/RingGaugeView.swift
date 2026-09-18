import SwiftUI

/// Apple Watch 활동 링 모양의 계정 게이지. 링 3개 = 5시간 / 주간 전체 / 주간 모델별.
public struct RingGaugeView: View {
    public var account: AccountUsage?
    public var warnThreshold: Double

    public init(account: AccountUsage?, warnThreshold: Double = 90) {
        self.account = account; self.warnThreshold = warnThreshold
    }

    public static let colors: [Color] = [
        Color(red: 1.00, green: 0.71, blue: 0.28),  // 호박 #FFB547 (focus-play 별)
        Color(red: 0.70, green: 0.42, blue: 1.00),  // 보라 #B36BFF (focus-play 강조)
        Color(red: 0.30, green: 0.89, blue: 0.76),  // 민트 #4DE3C1
    ]
    public static let alert = Color(red: 1.0, green: 0.23, blue: 0.19)

    public var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let line = size * 0.12
            let gap = size * 0.015
            ZStack {
                ForEach(RingSlot.allCases, id: \.rawValue) { slot in
                    let inset = CGFloat(slot.rawValue) * (line + gap) + line / 2
                    ring(slot: slot, line: line).padding(inset)
                }
            }
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    @ViewBuilder
    private func ring(slot: RingSlot, line: CGFloat) -> some View {
        let base = Self.colors[slot.rawValue]
        let failed = account == nil || account?.status == .expired || account?.status == .error
        if failed {
            Circle().stroke(Color.gray.opacity(0.5), style: StrokeStyle(lineWidth: line * 0.5, dash: [line * 0.5, line * 0.5]))
        } else {
            let limit = account?.limit(for: slot)
            let flagged = (limit?.percent ?? 0) >= warnThreshold || limit?.severity != nil
                || (account?.warning != nil && limit != nil && (limit?.percent ?? 0) >= 100)
            let color = flagged ? Self.alert : base
            ZStack {
                Circle().stroke(base.opacity(0.22), lineWidth: line)
                if let limit {
                    Circle()
                        .trim(from: 0, to: max(0.001, min(1, limit.percent / 100)))
                        .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            }
        }
    }
}
