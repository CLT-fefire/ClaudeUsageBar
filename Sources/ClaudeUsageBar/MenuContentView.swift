import SwiftUI

struct MenuContentView: View {
    @ObservedObject var monitor: UsageMonitor

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider().opacity(0.5)
            heroSection
            secondaryQuotas
            Divider().opacity(0.5)
            controlsSection
        }
        .frame(width: 340)
    }

    // MARK: - Title Bar

    @ViewBuilder
    private var titleBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tint)
            Text("Claude Usage")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            if let sub = monitor.snapshot?.subscriptionType {
                subscriptionBadge(sub)
            }
            if monitor.isProbing {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func subscriptionBadge(_ raw: String) -> some View {
        Text(raw.uppercased())
            .font(.system(size: 9, weight: .bold))
            .tracking(0.4)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
            .foregroundStyle(Color.accentColor)
    }

    // MARK: - Hero (Session)

    @ViewBuilder
    private var heroSection: some View {
        if let session = monitor.snapshot?.session {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("현재 세션")
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("\(session.percentUsed)")
                                .font(.system(size: 38, weight: .bold, design: .rounded))
                                .foregroundStyle(barColor(session.percentUsed))
                                .contentTransition(.numericText())
                                .monospacedDigit()
                            Text("%")
                                .font(.system(size: 18, weight: .semibold, design: .rounded))
                                .foregroundStyle(barColor(session.percentUsed).opacity(0.7))
                                .baselineOffset(2)
                        }
                    }
                    Spacer()
                    if let reset = session.resetsAt {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("리셋까지")
                                .font(.system(size: 9, weight: .semibold))
                                .tracking(0.6)
                                .foregroundStyle(.secondary)
                            Text(formatResetCompact(reset))
                                .font(.system(size: 14, weight: .medium, design: .monospaced))
                                .foregroundStyle(.primary)
                        }
                    }
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.primary.opacity(0.08))
                        RoundedRectangle(cornerRadius: 3)
                            .fill(barColor(session.percentUsed))
                            .frame(width: max(2, geo.size.width * CGFloat(session.percentUsed) / 100))
                    }
                }
                .frame(height: 6)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        } else if let err = monitor.lastError {
            errorView(err)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Claude 서버에서 조회 중…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(14)
        }
    }

    // MARK: - Secondary Quotas

    @ViewBuilder
    private var secondaryQuotas: some View {
        if let quotas = monitor.snapshot?.quotas {
            let others = quotas.filter { $0.kind != .fiveHour }
            if !others.isEmpty {
                Divider().opacity(0.5)
                VStack(spacing: 6) {
                    ForEach(others) { quota in
                        secondaryRow(quota)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }

    private func secondaryRow(_ q: ClaudeUsageProbe.Quota) -> some View {
        HStack(spacing: 10) {
            Text(shortLabel(q.kind))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
                .lineLimit(1)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.06))
                    Capsule()
                        .fill(barColor(q.percentUsed))
                        .frame(width: max(2, geo.size.width * CGFloat(q.percentUsed) / 100))
                }
            }
            .frame(height: 4)

            Text("\(q.percentUsed)%")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(barColor(q.percentUsed))
                .frame(width: 36, alignment: .trailing)
                .monospacedDigit()
        }
        .help(q.resetsAt.map { "리셋: \(formatResetCompact($0)) 후" } ?? "")
    }

    // MARK: - Controls

    @ViewBuilder
    private var controlsSection: some View {
        VStack(spacing: 10) {
            // Refresh interval segmented picker
            HStack(spacing: 8) {
                Label {
                    Text("자동 갱신")
                        .font(.system(size: 11, weight: .medium))
                } icon: {
                    Image(systemName: "timer")
                        .font(.system(size: 10))
                }
                .foregroundStyle(.secondary)
                Spacer()
                segmentedIntervalPicker
            }

            // Status line
            HStack(spacing: 0) {
                Image(systemName: "clock")
                    .font(.system(size: 9))
                Text(" 마지막 \(formatLastUpdated())")
                Spacer()
                if monitor.nextRefreshAt != .distantFuture {
                    Text("다음 \(formatNextRefresh())")
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9))
                        .padding(.leading, 2)
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.tertiary)

            // Action buttons
            HStack(spacing: 8) {
                Button {
                    monitor.manualRefresh()
                } label: {
                    Label("새로고침", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut("r", modifiers: .command)
                .controlSize(.small)
                .buttonStyle(.bordered)

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("종료", systemImage: "power")
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut("q", modifiers: .command)
                .controlSize(.small)
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var segmentedIntervalPicker: some View {
        HStack(spacing: 2) {
            ForEach(UsageMonitor.availableIntervals, id: \.self) { sec in
                let isSelected = monitor.refreshIntervalSeconds == sec
                Button {
                    monitor.refreshIntervalSeconds = sec
                } label: {
                    Text("\(sec / 60)m")
                        .font(.system(size: 10,
                                      weight: isSelected ? .semibold : .regular,
                                      design: .monospaced))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .frame(minWidth: 28, minHeight: 18)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(isSelected
                                      ? Color.primary.opacity(0.14)
                                      : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    // MARK: - Error

    private func errorView(_ err: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("조회 실패")
                    .font(.system(size: 12, weight: .semibold))
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(4)
            }
        }
        .padding(14)
    }

    // MARK: - Formatting

    private func shortLabel(_ kind: ClaudeUsageProbe.Quota.Kind) -> String {
        switch kind {
        case .fiveHour: return "세션 5h"
        case .sevenDay: return "주간 전체"
        case .sevenDayOpus: return "주간 Opus"
        case .sevenDaySonnet: return "주간 Sonnet"
        case .sevenDayOmelette: return "주간 Design"
        }
    }

    private func formatResetCompact(_ date: Date) -> String {
        let delta = date.timeIntervalSinceNow
        if delta <= 0 { return "지금" }
        let total = Int(delta)
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    private func formatLastUpdated() -> String {
        if monitor.lastUpdated == .distantPast { return "—" }
        return monitor.lastUpdated.formatted(date: .omitted, time: .shortened)
    }

    private func formatNextRefresh() -> String {
        let delta = monitor.nextRefreshAt.timeIntervalSinceNow
        if delta <= 0 { return "곧" }
        let m = Int(delta) / 60
        let s = Int(delta) % 60
        return m > 0 ? "\(m)m\(s)s" : "\(s)s"
    }

    private func barColor(_ pct: Int) -> Color {
        switch pct {
        case ..<60: return .green
        case ..<85: return .orange
        default: return .red
        }
    }
}
