import Foundation

/// `status.claude.com` (Atlassian Statuspage) 의 공개 요약 API를 폴링해서
/// Claude 서비스 상태를 가져온다.
///
/// - 인증 불필요 → 로그아웃 상태에서도 동작한다 (사용량 API와 독립).
/// - `status.anthropic.com` 은 302로 이 호스트에 리다이렉트되므로 캐노니컬만 쓴다.
/// - RSS/Atom(`/history.rss`, `/history.atom`)은 "현재 상태"가 아니라 인시던트 *이력*이고
///   컴포넌트별 상태가 없으며 본문이 HTML 이스케이프 덩어리라 쓰지 않는다.
///   `summary.json`은 2KB대에 현재 상태·컴포넌트·진행중 인시던트를 한 번에 준다.
struct StatusProbe {

    /// 메뉴에서 "열기"로 띄우는 사람용 페이지.
    static let pageURL = URL(string: "https://status.claude.com")!
    private static let summaryURL = URL(string: "https://status.claude.com/api/v2/summary.json")!

    // MARK: - Domain

    /// 페이지 전체 심각도 (Statuspage `status.indicator`).
    /// `Optional.none` 과의 혼동을 피하려고 케이스 이름만 `allClear` 로 둔다.
    enum Indicator: String, Sendable {
        case allClear = "none"
        case minor
        case major
        case critical
        case maintenance
        case unknown

        init(raw: String?) { self = Indicator(rawValue: raw ?? "") ?? .unknown }

        var summary: String {
            switch self {
            case .allClear: return "모든 시스템 정상"
            case .minor: return "일부 성능 저하"
            case .major: return "장애 발생"
            case .critical: return "심각한 장애"
            case .maintenance: return "점검 진행 중"
            case .unknown: return "상태 불명"
            }
        }
    }

    enum ComponentStatus: String, Sendable {
        case operational
        case degradedPerformance = "degraded_performance"
        case partialOutage = "partial_outage"
        case majorOutage = "major_outage"
        case underMaintenance = "under_maintenance"
        case unknown

        init(raw: String?) { self = ComponentStatus(rawValue: raw ?? "") ?? .unknown }

        var isOperational: Bool { self == .operational }

        /// **실제 장애로 볼 상태.** `!isOperational` 과 구분해야 한다 —
        /// `underMaintenance`(예고된 작업)와 `unknown`(Statuspage가 어휘를 늘렸을 때의 폴백)을
        /// 장애로 세면 정상인데 경보가 뜬다. 전방호환 폴백은 fail-soft여야 한다.
        var isDegraded: Bool {
            switch self {
            case .degradedPerformance, .partialOutage, .majorOutage: return true
            case .operational, .underMaintenance, .unknown: return false
            }
        }

        var label: String {
            switch self {
            case .operational: return "정상"
            case .degradedPerformance: return "성능 저하"
            case .partialOutage: return "일부 장애"
            case .majorOutage: return "전면 장애"
            case .underMaintenance: return "점검 중"
            case .unknown: return "알 수 없음"
            }
        }

        /// 컴포넌트 단위 심각도를 페이지 indicator 색 체계에 맞춘다.
        var indicator: Indicator {
            switch self {
            case .operational: return .allClear
            case .degradedPerformance: return .minor
            case .partialOutage: return .major
            case .majorOutage: return .critical
            case .underMaintenance: return .maintenance
            case .unknown: return .unknown
            }
        }
    }

    struct Component: Identifiable, Sendable {
        let id: String
        let name: String
        let status: ComponentStatus
    }

    struct Incident: Identifiable, Sendable {
        let id: String
        let name: String
        let impact: Indicator
        let url: URL?
        /// Statuspage `status`. 점검(`scheduled_maintenances`)은 2주 뒤 예정 건도
        /// summary에 실려 오므로, 진행 중인 것만 걸러내는 데 쓴다.
        let isInProgress: Bool
    }

    struct Snapshot: Sendable {
        let indicator: Indicator
        /// API 원문 문구 ("All Systems Operational" 등). 툴팁용.
        let rawDescription: String?
        let components: [Component]
        let incidents: [Incident]
        let maintenances: [Incident]
        let capturedAt: Date

        /// 카드를 접어둘 수 있는 상태인지. 점검 중도 "정상"은 아니므로 여기엔 걸린다.
        var isHealthy: Bool {
            indicator == .allClear && incidents.isEmpty && noteworthyComponents.isEmpty
        }

        /// **메뉴바 경보 대상 — 실제 장애만.** `isHealthy` 와 분리한 이유:
        /// 예정된 점검이나 미지 상태로 메뉴바에 경고 삼각형이 뜨면 오탐이고,
        /// 오탐이 한 번 나면 다음 진짜 경보도 같은 취급을 받는다.
        var hasOutage: Bool {
            switch indicator {
            case .minor, .major, .critical:
                return true
            case .allClear, .maintenance, .unknown:
                // 페이지 indicator가 장애를 선언하지 않아도 컴포넌트/인시던트가 있으면 장애.
                return !degradedComponents.isEmpty || !incidents.isEmpty
            }
        }

        /// 장애 컴포넌트(점검·미지 제외). 경보 판정에 쓴다.
        var degradedComponents: [Component] {
            components.filter { $0.status.isDegraded }
        }

        /// 접힌 카드에 노출할 "정상이 아닌" 컴포넌트 = 장애 + 점검 중.
        /// `unknown` 은 사용자가 할 수 있는 게 없고 어휘 확장 시 노이즈라 제외한다.
        var noteworthyComponents: [Component] {
            components.filter { $0.status.isDegraded || $0.status == .underMaintenance }
        }
    }

    enum ProbeError: Error, LocalizedError {
        case http(status: Int)
        case network(Error)
        case parse(String)

        var errorDescription: String? {
            switch self {
            case .http(let status): return "상태 페이지 HTTP \(status)"
            case .network(let err): return "네트워크 오류: \(err.localizedDescription)"
            case .parse(let detail): return "상태 응답 파싱 실패: \(detail)"
            }
        }
    }

    private let session: URLSession

    /// 기본값이 `.shared` 가 아닌 이유: `.shared` 는 OAuth 토큰 교환과 쿠키 저장소
    /// (`HTTPCookieStorage.shared`)를 공유한다. 상태 조회는 미인증 요청이므로
    /// 인증 요청과 쿠키 자를 섞을 이유가 없다. ephemeral은 디스크 캐시도 안 쓴다.
    init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    // MARK: - Fetch

    func probe() async throws -> Snapshot {
        var request = URLRequest(url: Self.summaryURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        // 상태는 폴링 시점의 값이어야 하므로 URLCache의 재사용을 막는다.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ProbeError.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ProbeError.parse("HTTPURLResponse 아님")
        }
        guard http.statusCode == 200 else {
            throw ProbeError.http(status: http.statusCode)
        }

        return try Self.parse(data)
    }

    // MARK: - Parsing

    /// 스키마가 안정적인 공개 API라 Codable DTO로 받는다.
    /// (사용량 API와 달리 자기서술형 필드가 없어서 JSONSerialization 수작업이 불필요)
    private struct SummaryDTO: Decodable {
        struct StatusDTO: Decodable {
            let indicator: String?
            let description: String?
        }
        struct ComponentDTO: Decodable {
            let id: String
            let name: String
            let status: String?
            /// 그룹 헤더 여부. true면 자식들을 묶는 껍데기라 목록에서 제외한다.
            let group: Bool?
        }
        struct IncidentDTO: Decodable {
            let id: String
            let name: String
            let status: String?
            let impact: String?
            let shortlink: String?
        }
        let status: StatusDTO?
        let components: [ComponentDTO]?
        let incidents: [IncidentDTO]?
        let scheduledMaintenances: [IncidentDTO]?
    }

    /// 검증 하네스가 픽스처를 실제 파서에 통과시킬 수 있도록 internal.
    static func parse(_ data: Data) throws -> Snapshot {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let dto: SummaryDTO
        do {
            dto = try decoder.decode(SummaryDTO.self, from: data)
        } catch {
            throw ProbeError.parse(error.localizedDescription)
        }

        let components = (dto.components ?? [])
            .filter { $0.group != true }
            .map { Component(id: $0.id, name: $0.name, status: ComponentStatus(raw: $0.status)) }

        return Snapshot(
            indicator: Indicator(raw: dto.status?.indicator),
            rawDescription: dto.status?.description,
            components: components,
            incidents: (dto.incidents ?? []).map(Self.makeIncident),
            // 점검은 **진행 중인 것만.** summary에는 2주 뒤 예정 건도 실려 오는데,
            // 그대로 담으면 전 서비스 정상인 채로 카드가 2주 내내 펼쳐진다.
            maintenances: (dto.scheduledMaintenances ?? []).map(Self.makeIncident).filter(\.isInProgress),
            capturedAt: Date()
        )
    }

    private static func makeIncident(_ dto: SummaryDTO.IncidentDTO) -> Incident {
        // `resolved`/`completed`/`scheduled` 를 제외한 나머지가 "지금 벌어지는 일".
        let inactive: Set<String> = ["resolved", "completed", "postmortem", "scheduled"]
        let isInProgress = !inactive.contains(dto.status ?? "")

        return Incident(
            id: dto.id,
            name: dto.name,
            impact: Indicator(raw: dto.impact),
            url: dto.shortlink.flatMap(URL.init(string:)).flatMap(Self.safeExternalURL),
            isInProgress: isInProgress
        )
    }

    /// 원격 JSON에서 온 URL은 그대로 `NSWorkspace.open` 에 넘기지 않는다.
    /// 이 앱은 샌드박스 없이 서명되므로 열린 핸들러가 사용자 권한 전체를 갖는다 —
    /// `smb://`·`file://`·악성 앱이 등록한 커스텀 스킴이 확인창 없이 실행될 수 있다.
    /// https + 알려진 호스트만 통과시키고, 나머지는 nil(= 링크 비활성)로 떨어뜨린다.
    private static func safeExternalURL(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https" else { return nil }
        guard let host = url.host()?.lowercased() else { return nil }
        let allowed = ["stspg.io", "status.claude.com", "status.anthropic.com"]
        guard allowed.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) else { return nil }
        return url
    }
}
