import SwiftUI

struct MenuContentView: View {
    @ObservedObject var monitor: UsageMonitor
    @State private var launchAtLoginEnabled = LaunchAtLogin.isEnabled
    @State private var codeInput: String = ""

    var body: some View {
        VStack(spacing: 0) {
            titleBar
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)

            GlassEffectContainer(spacing: 14) {
                VStack(spacing: 10) {
                    if monitor.isAuthenticated {
                        heroCard
                        if let snapshot = monitor.snapshot {
                            let others = snapshot.quotas.filter { $0.group != .session }
                            if !others.isEmpty {
                                secondaryCard(others)
                            }
                        }
                        controlsCard
                    } else {
                        authCard
                        appControlsCard
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 14)
            }
        }
        .frame(width: 360)
    }

    // MARK: - Auth Card

    @ViewBuilder
    private var authCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if monitor.isAwaitingCode {
                Text("브라우저에서 로그인한 뒤, 표시되는 인증 코드를 붙여넣으세요.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextField("인증 코드 붙여넣기", text: $codeInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit { submitCode() }

                if let err = monitor.loginError {
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(3)
                }

                HStack(spacing: 8) {
                    Button {
                        monitor.cancelLogin()
                        codeInput = ""
                    } label: {
                        Text("취소").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.regular)

                    Button {
                        submitCode()
                    } label: {
                        Label("확인", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.regular)
                    .keyboardShortcut(.defaultAction)
                    .disabled(codeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 22))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Claude에 로그인")
                            .font(.system(size: 13, weight: .semibold))
                        Text("사용량을 보려면 Claude 계정으로 로그인하세요.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let err = monitor.loginError {
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(3)
                }

                Button {
                    monitor.startLogin()
                } label: {
                    Label("Claude 로그인", systemImage: "arrow.up.forward.app")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.regular)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 16))
    }

    private func submitCode() {
        monitor.submitCode(codeInput)
        codeInput = ""
    }

    // MARK: - App Controls (로그인 전 화면용: 자동시작/종료만)

    private var appControlsCard: some View {
        VStack(spacing: 12) {
            launchAtLoginRow
            HStack(spacing: 8) {
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
            return .clear.tint(barColor(session).opacity(0.10))
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
                            .foregroundStyle(barColor(session))
                            .contentTransition(.numericText())
                            .monospacedDigit()
                        Text("%")
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .foregroundStyle(barColor(session).opacity(0.7))
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
                                barColor(session),
                                barColor(session).opacity(0.7)
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
            if let reset = weeklyResetDate(quotas) {
                Divider().opacity(0.4)
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9))
                    Text("주간 리셋까지 \(formatResetCompact(reset))")
                    Spacer()
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 14))
    }

    /// 주간 quota들의 대표 리셋 시각. 7일 윈도우는 공통이므로 `weekly_all`을
    /// 우선 쓰고, 없으면 첫 주간 항목, 그래도 없으면 가장 먼저 발견되는 값을 쓴다.
    private func weeklyResetDate(_ quotas: [ClaudeUsageProbe.Quota]) -> Date? {
        if let main = quotas.first(where: { $0.kind == "weekly_all" })?.resetsAt {
            return main
        }
        if let weekly = quotas.first(where: { $0.group == .weekly })?.resetsAt {
            return weekly
        }
        return quotas.compactMap { $0.resetsAt }.first
    }

    private func secondaryRow(_ q: ClaudeUsageProbe.Quota) -> some View {
        HStack(spacing: 10) {
            Text(shortLabel(q))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
                .lineLimit(1)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.08))
                    Capsule()
                        .fill(barColor(q))
                        .frame(width: max(2, geo.size.width * CGFloat(q.percentUsed) / 100))
                }
            }
            .frame(height: 4)

            Text("\(q.percentUsed)%")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(barColor(q))
                .frame(width: 36, alignment: .trailing)
                .monospacedDigit()
        }
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

            launchAtLoginRow

            HStack(spacing: 0) {
                Image(systemName: "clock")
                    .font(.system(size: 9))
                Text(" 마지막 갱신 \(formatLastUpdated())")
                Spacer()
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
                    monitor.signOut()
                } label: {
                    Label("로그아웃", systemImage: "rectangle.portrait.and.arrow.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.regular)

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

    private var launchAtLoginRow: some View {
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

    /// 데이터 주도 라벨. weekly_scoped는 서버가 준 scope 모델명(예: "Sonnet")을 그대로 쓴다.
    private func shortLabel(_ q: ClaudeUsageProbe.Quota) -> String {
        switch q.kind {
        case "session": return "세션 5h"
        case "weekly_all": return "주간 전체"
        case "weekly_scoped": return "주간 \(q.scopeLabel ?? "모델")"
        default: return q.scopeLabel ?? q.kind
        }
    }

    private func formatResetCompact(_ date: Date) -> String {
        let delta = date.timeIntervalSinceNow
        if delta <= 0 { return "지금" }
        let total = Int(delta)
        let d = total / 86400
        let h = (total % 86400) / 3600
        let m = (total % 3600) / 60
        if d > 0 { return "\(d)일 \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    private func formatLastUpdated() -> String {
        if monitor.lastUpdated == .distantPast { return "—" }
        return monitor.lastUpdated.formatted(date: .omitted, time: .shortened)
    }

    /// 색상은 서버 severity를 우선 반영하고(warning/critical), normal·unknown이면
    /// 퍼센트 임계값으로 폴백한다. (서버가 낮은 %에서도 critical을 줄 수 있으므로)
    private func barColor(_ q: ClaudeUsageProbe.Quota) -> Color {
        switch q.severity {
        case .critical: return .red
        case .warning: return .orange
        case .normal, .unknown: return barColor(q.percentUsed)
        }
    }

    private func barColor(_ pct: Int) -> Color {
        switch pct {
        case ..<60: return .green
        case ..<85: return .orange
        default: return .red
        }
    }
}
