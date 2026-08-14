import SwiftUI
import AppKit

/// 스냅샷을 한 번도 못 받았을 때의 자리표시 카드.
/// 카드가 아예 렌더되지 않으면 사용자는 상태 기능이 있다는 것조차 모른다.
struct StatusUnavailableCard: View {
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(theme.palette.hairline)
                .frame(width: 7, height: 7)
            Text("서비스 상태 확인 불가")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.tertiaryStyle)
            Spacer(minLength: 4)
            Button {
                NSWorkspace.shared.open(StatusProbe.pageURL)
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 10))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.tertiaryStyle)
            .help("status.claude.com 열기")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .themedCard(theme, radius: Metrics.cardMedium)
    }
}

/// status.claude.com 서비스 상태 카드.
///
/// 정상일 땐 한 줄(점 + 요약 + 열기), 문제가 있으면 인시던트와 비정상 컴포넌트를
/// 펼쳐 보여준다. 셰브론으로 전체 컴포넌트 목록을 토글한다.
struct StatusCard: View {
    let snapshot: StatusProbe.Snapshot
    /// 직전 조회가 실패했는지 (마지막 스냅샷은 유지되므로 stale임을 표시).
    var failed: Bool = false
    @Binding var expanded: Bool

    @Environment(\.theme) private var theme

    /// 접힌 상태에서도 보여줘야 할 내용이 있는지.
    private var hasDetail: Bool {
        !snapshot.incidents.isEmpty
            || !snapshot.maintenances.isEmpty
            || !snapshot.noteworthyComponents.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if expanded || hasDetail {
                Divider().opacity(Metrics.dividerOpacity)
                detail
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, expanded || hasDetail ? 12 : 9)
        .frame(maxWidth: .infinity)
        .themedCard(theme, radius: Metrics.cardMedium)
    }

    private var header: some View {
        let color = theme.statusColor(snapshot.indicator)
        return HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)

            Text(snapshot.indicator.summary)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(snapshot.isHealthy ? theme.secondaryStyle : AnyShapeStyle(color))

            if failed {
                Text("· 확인 불가")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.tertiaryStyle)
            }

            Spacer(minLength: 4)

            Button {
                expanded.toggle()
            } label: {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.tertiaryStyle)
            .help(expanded ? "접기" : "전체 서비스 보기")

            Button {
                NSWorkspace.shared.open(StatusProbe.pageURL)
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 10))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.tertiaryStyle)
            .help("status.claude.com 열기")
        }
        .help(snapshot.rawDescription ?? "")
    }

    private var detail: some View {
        // 펼치면 전체 컴포넌트, 접혀 있으면 정상이 아닌 것만(장애 + 점검 중).
        let rows = expanded ? snapshot.components : snapshot.noteworthyComponents

        return VStack(alignment: .leading, spacing: 7) {
            ForEach(snapshot.incidents + snapshot.maintenances) { incident in
                // url은 StatusProbe가 https + 알려진 호스트만 통과시킨 값이다(nil이면 링크 없음).
                Button {
                    if let url = incident.url { NSWorkspace.shared.open(url) }
                } label: {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(theme.statusColor(incident.impact))
                            .padding(.top, 2)
                        Text(incident.name)
                            .font(.system(size: 10))
                            .foregroundStyle(theme.secondaryStyle)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(incident.url == nil)
            }

            ForEach(rows) { component in
                HStack(spacing: 8) {
                    Text(component.name)
                        .font(.system(size: 10))
                        .foregroundStyle(theme.tertiaryStyle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(component.status.label)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.statusColor(component.status.indicator))
                }
            }
        }
    }
}
