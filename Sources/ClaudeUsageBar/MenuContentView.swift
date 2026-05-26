import SwiftUI

struct MenuContentView: View {
    @ObservedObject var monitor: UsageMonitor
    @State private var launchAtLoginEnabled = LaunchAtLogin.isEnabled

    var body: some View {
        VStack(spacing: 0) {
            titleBar
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)

            GlassEffectContainer(spacing: 14) {
                VStack(spacing: 10) {
                    heroCard
                    if let snapshot = monitor.snapshot {
                        let others = snapshot.quotas.filter { $0.kind != .fiveHour }
                        if !others.isEmpty {
                            secondaryCard(others)
                        }
                    }
                    controlsCard
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 14)
            }
        }
        .frame(width: 360)
    }

    // MARK: - Title Bar

    @ViewBuilder
    private var titleBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tint)
            Text("Claude Usage")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if let sub = monitor.snapshot?.subscriptionType {
                subscriptionBadge(sub)
            }
            if monitor.isProbing {
                ProgressView().controlSize(.mini)
            }
        }
    }

    private func subscriptionBadge(_ raw: String) -> some View {
        Text(raw.uppercased())
            .font(.system(size: 9, weight: .bold))
            .tracking(0.5)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(.tint)
            .glassEffect(.clear.tint(.accentColor.opacity(0.12)), in: Capsule())
    }

    // MARK: - Hero Card

    @ViewBuilder
    private var heroCard: some View {
        Group {
            if let session = monitor.snapshot?.session {
                heroContent(session)
            } else if let err = monitor.lastError {
                errorContent(err)
            } else {
                loadingContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassEffect(heroGlass, in: RoundedRectangle(cornerRadius: 16))
    }

    private var heroGlass: Glass {
        if let session = monitor.snapshot?.session {
            // .clear + 매우 옅은 tint로 진짜 유리처럼 뒷배경이 비치게.
            return .clear.tint(barColor(session.percentUsed).opacity(0.10))
        }
        return .clear
    }

    @ViewBuilder
    private func heroContent(_ session: ClaudeUsageProbe.Quota) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("현재 세션")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(session.percentUsed)")
                            .font(.system(size: 44, weight: .bold, design: .rounded))
                            .foregroundStyle(barColor(session.percentUsed))
                            .contentTransition(.numericText())
                            .monospacedDigit()
                        Text("%")
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .foregroundStyle(barColor(session.percentUsed).opacity(0.7))
                            .baselineOffset(4)
                    }
                }
                Spacer()
                if let reset = session.resetsAt {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("리셋까지")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(.secondary)
                        Text(formatResetCompact(reset))
                            .font(.system(size: 15, weight: .medium, design: .monospaced))
                            .foregroundStyle(.primary)
                    }
                }
            }
            heroProgressBar(session)
        }
    }

    private func heroProgressBar(_ session: ClaudeUsageProbe.Quota) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.12))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                barColor(session.percentUsed),
                                barColor(session.percentUsed).opacity(0.7)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(2, geo.size.width * CGFloat(session.percentUsed) / 100))
            }
        }
        .frame(height: 7)
    }

    private var loadingContent: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Claude 서버에서 조회 중…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func errorContent(_ err: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 20))
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
    }

    // MARK: - Secondary Quotas Card

    private func secondaryCard(_ quotas: [ClaudeUsageProbe.Quota]) -> some View {
        VStack(spacing: 10) {
            ForEach(quotas) { quota in
                secondaryRow(quota)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 14))
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
                        .fill(.white.opacity(0.08))
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

    // MARK: - Controls Card

    private var controlsCard: some View {
        VStack(spacing: 12) {
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

            HStack(spacing: 8) {
                Label {
                    Text("로그인 시 시작")
                        .font(.system(size: 11, weight: .medium))
                } icon: {
                    Image(systemName: "power.circle")
                        .font(.system(size: 10))
                }
                .foregroundStyle(.secondary)
                Spacer()
                Toggle("", isOn: $launchAtLoginEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .onChange(of: launchAtLoginEnabled) { _, newValue in
                        let success = LaunchAtLogin.setEnabled(newValue)
                        if !success {
                            // 등록 실패 시 실제 상태로 되돌림
                            launchAtLoginEnabled = LaunchAtLogin.isEnabled
                        }
                    }
            }

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

            HStack(spacing: 8) {
                Button {
                    monitor.manualRefresh()
                } label: {
                    Label("새로고침", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.regular)
                .keyboardShortcut("r", modifiers: .command)

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("종료", systemImage: "power")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.regular)
                .keyboardShortcut("q", modifiers: .command)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 14))
    }

    private var segmentedIntervalPicker: some View {
        HStack(spacing: 4) {
            ForEach(UsageMonitor.availableIntervals, id: \.self) { sec in
                let isSelected = monitor.refreshIntervalSeconds == sec
                Button {
                    monitor.refreshIntervalSeconds = sec
                } label: {
                    Text("\(sec / 60)m")
                        .font(.system(
                            size: 10,
                            weight: isSelected ? .semibold : .medium,
                            design: .monospaced
                        ))
                        .foregroundStyle(isSelected ? Color.white : Color.secondary)
                        .frame(minWidth: 32, minHeight: 22)
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.plain)
                .glassEffect(
                    isSelected
                        ? .clear.tint(.accentColor.opacity(0.55)).interactive()
                        : .clear.interactive(),
                    in: Capsule()
                )
            }
        }
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
