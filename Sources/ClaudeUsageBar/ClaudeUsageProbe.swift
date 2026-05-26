import Foundation

/// `https://api.anthropic.com/api/oauth/usage` 를 호출해서
/// 5h / 7d / Sonnet / Omelette 등의 quota %를 가져온다.
///
/// 인증: Keychain의 Claude OAuth access token (CredentialStore.load()).
/// claude.ai 웹 페이지가 보여주는 것과 동일한 데이터 (둘 다 같은 백엔드).
struct ClaudeUsageProbe {

    struct Quota: Hashable, Identifiable {
        let kind: Kind
        let utilization: Double  // 0~100 (서버가 이미 0.0~100.0 스케일로 반환)
        let resetsAt: Date?

        var id: Kind { kind }
        var percentUsed: Int { Int(utilization.rounded()) }

        enum Kind: String, CaseIterable {
            case fiveHour
            case sevenDay
            case sevenDayOpus
            case sevenDaySonnet
            case sevenDayOmelette

            var apiKey: String {
                switch self {
                case .fiveHour: return "five_hour"
                case .sevenDay: return "seven_day"
                case .sevenDayOpus: return "seven_day_opus"
                case .sevenDaySonnet: return "seven_day_sonnet"
                case .sevenDayOmelette: return "seven_day_omelette"
                }
            }

            var displayName: String {
                switch self {
                case .fiveHour: return "현재 세션 (5h)"
                case .sevenDay: return "주간 (모든 모델)"
                case .sevenDayOpus: return "주간 (Opus)"
                case .sevenDaySonnet: return "주간 (Sonnet)"
                case .sevenDayOmelette: return "주간 (Design)"
                }
            }
        }
    }

    struct Snapshot {
        let quotas: [Quota]
        let subscriptionType: String?
        let extraUsageEnabled: Bool
        let capturedAt: Date

        var session: Quota? { quotas.first { $0.kind == .fiveHour } }
    }

    enum ProbeError: Error, LocalizedError {
        case credentials(CredentialStore.LoadError)
        case tokenExpired(Date)
        case http(status: Int, body: String?)
        case network(Error)
        case parse(String)
        case rateLimited(retryAfter: Date)

        var errorDescription: String? {
            switch self {
            case .credentials(let err): return err.localizedDescription
            case .tokenExpired(let when):
                return "OAuth 토큰이 \(when.formatted())에 만료되었습니다. Claude Desktop을 열어 자동 갱신하거나, 'claude /login'으로 재로그인하세요."
            case .http(let status, let body):
                let detail = body?.prefix(200) ?? ""
                return "HTTP \(status): \(detail)"
            case .network(let err): return "네트워크 오류: \(err.localizedDescription)"
            case .parse(let detail): return "응답 파싱 실패: \(detail)"
            case .rateLimited(let retry):
                return "Rate limit 적용 중 (\(retry.formatted())까지 대기)"
            }
        }
    }

    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func probe() async throws -> Snapshot {
        let creds: CredentialStore.Credentials
        do {
            creds = try CredentialStore.load()
        } catch let err as CredentialStore.LoadError {
            throw ProbeError.credentials(err)
        }

        if let exp = creds.expiresAt, exp < Date() {
            throw ProbeError.tokenExpired(exp)
        }

        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

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

        switch http.statusCode {
        case 200:
            break
        case 401:
            throw ProbeError.tokenExpired(Date())
        case 429:
            let retryAt = Self.parseRetryAfter(http.value(forHTTPHeaderField: "Retry-After"))
            throw ProbeError.rateLimited(retryAfter: retryAt)
        default:
            let body = String(data: data, encoding: .utf8)
            throw ProbeError.http(status: http.statusCode, body: body)
        }

        return try Self.parseResponse(data, subscriptionType: creds.subscriptionType)
    }

    // MARK: - Parsing

    private static func parseResponse(_ data: Data, subscriptionType: String?) throws -> Snapshot {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProbeError.parse("응답이 JSON 객체 아님")
        }

        var quotas: [Quota] = []
        for kind in Quota.Kind.allCases {
            guard let obj = raw[kind.apiKey] as? [String: Any],
                  let utilization = obj["utilization"] as? Double else {
                continue
            }
            let resetsAt = (obj["resets_at"] as? String).flatMap(Self.isoDate)
            quotas.append(Quota(kind: kind, utilization: utilization, resetsAt: resetsAt))
        }

        let extra = raw["extra_usage"] as? [String: Any]
        let extraEnabled = (extra?["is_enabled"] as? Bool) ?? false

        return Snapshot(
            quotas: quotas,
            subscriptionType: subscriptionType,
            extraUsageEnabled: extraEnabled,
            capturedAt: Date()
        )
    }

    /// ISO8601DateFormatter는 Sendable이 아니라서 static let 캐시는 strict concurrency에서 금지.
    /// 호출 빈도가 낮으니(폴링당 5~6회) 매번 새로 만들어도 비용 무시 가능.
    private static func isoDate(_ s: String) -> Date? {
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFrac.date(from: s) { return d }

        let noFrac = ISO8601DateFormatter()
        noFrac.formatOptions = [.withInternetDateTime]
        return noFrac.date(from: s)
    }

    private static func parseRetryAfter(_ header: String?) -> Date {
        let fallback = Date().addingTimeInterval(5 * 60)
        guard let header else { return fallback }
        if let seconds = TimeInterval(header) {
            return Date().addingTimeInterval(seconds)
        }
        return fallback
    }
}
