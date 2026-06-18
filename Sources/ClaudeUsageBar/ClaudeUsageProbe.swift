import Foundation

/// `https://api.anthropic.com/api/oauth/usage` 를 호출해서
/// 5h / 7d / Sonnet / Omelette 등의 quota %를 가져온다.
///
/// 인증: 자체 파일에 저장된 Claude OAuth access token (CredentialStore.load()).
/// claude.ai 웹 페이지가 보여주는 것과 동일한 데이터 (둘 다 같은 백엔드).
struct ClaudeUsageProbe {

    /// 2026-06-15 정책 변경 이후 사용량 API는 `limits` 배열로 제한을 세분화해서 돌려준다.
    /// 각 항목은 자기서술형(kind/group/severity/scope)이라 고정 enum 대신
    /// 데이터 주도 모델로 받는다. (구버전 응답은 레거시 최상위 키에서 폴백 파싱)
    struct Quota: Hashable, Identifiable {
        let id: String           // 안정 식별자: kind(+scope)
        let group: Group         // session / weekly / other
        let kind: String         // 원본 kind ("session", "weekly_all", "weekly_scoped", …)
        let scopeLabel: String?  // scope.model.display_name (예: "Sonnet")
        let utilization: Double  // 0~100 (서버가 이미 0~100 스케일로 반환)
        let resetsAt: Date?
        let severity: Severity   // 서버 판정 심각도 (색상에 우선 반영)
        let isActive: Bool       // 현재 적용 중인 제한인지

        var percentUsed: Int { Int(utilization.rounded()) }

        enum Group: String {
            case session
            case weekly
            case other
        }

        enum Severity: String {
            case normal
            case warning
            case critical
            case unknown
        }
    }

    struct Snapshot {
        let quotas: [Quota]
        let subscriptionType: String?
        let extraUsageEnabled: Bool
        let capturedAt: Date

        var session: Quota? { quotas.first { $0.group == .session } }
    }

    enum ProbeError: Error, LocalizedError {
        case notSignedIn                  // 자격증명 파일 없음 → 로그인 UI로 전환
        case credentials(CredentialStore.LoadError)
        case unauthorized                 // 401 — 내부 신호 (갱신 후 재시도 트리거용)
        case reauthRequired               // 자동 갱신도 실패 → 사용자 재로그인 필요
        case http(status: Int, body: String?)
        case network(Error)
        case parse(String)
        case rateLimited(retryAfter: Date)

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                return "로그인이 필요합니다."
            case .credentials(let err): return err.localizedDescription
            case .unauthorized:
                return "인증 실패 (401)."
            case .reauthRequired:
                return "OAuth 토큰을 자동 갱신하지 못했습니다. Claude Desktop을 열거나 'claude /login'으로 재로그인하세요."
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

    /// 만료 임박으로 판단하는 여유 시간. access token이 이 시간 내에 죽으면
    /// 선제적으로 갱신해서 폴링 도중 401을 맞는 일을 줄인다.
    private static let expiryBuffer: TimeInterval = 60

    func probe() async throws -> Snapshot {
        var creds = try loadCredentials()

        // 1) 만료됐거나 임박했으면 호출 전에 미리 갱신
        if let exp = creds.expiresAt, exp.timeIntervalSinceNow < Self.expiryBuffer {
            creds = try await refreshCredentials(using: creds)
        }

        // 2) usage 조회. access token이 예상보다 일찍 죽어 401이 나면 1회 갱신 후 재시도.
        do {
            return try await fetchUsage(using: creds)
        } catch ProbeError.unauthorized {
            let refreshed = try await refreshCredentials(using: creds)
            return try await fetchUsage(using: refreshed)
        }
    }

    private func loadCredentials() throws -> CredentialStore.Credentials {
        do {
            return try CredentialStore.load()
        } catch CredentialStore.LoadError.notSignedIn {
            throw ProbeError.notSignedIn
        } catch let err as CredentialStore.LoadError {
            throw ProbeError.credentials(err)
        }
    }

    /// refreshToken으로 새 토큰을 발급받아 자체 파일에 write-back 하고,
    /// 메모리상의 자격증명도 갱신해서 돌려준다.
    private func refreshCredentials(
        using creds: CredentialStore.Credentials
    ) async throws -> CredentialStore.Credentials {
        let result: OAuthRefresher.Result
        do {
            result = try await OAuthRefresher.refresh(refreshToken: creds.refreshToken, session: session)
        } catch OAuthRefresher.RefreshError.invalidGrant,
                OAuthRefresher.RefreshError.noRefreshToken {
            // 토큰으로 회복 불가 → 사용자 재로그인만이 답
            throw ProbeError.reauthRequired
        } catch let err as OAuthRefresher.RefreshError {
            // 일시적 실패(네트워크/5xx 등)는 다음 폴링에서 재시도
            throw ProbeError.network(err)
        }

        // 회전된 refresh token 정합성 유지를 위해 자체 파일에 즉시 반영.
        // (공유 Keychain 항목이 아니라 이 앱 전용 파일이므로 ACL churn 없음)
        // write-back 자체가 실패해도 이번 폴링은 메모리 토큰으로 진행.
        let updated = CredentialStore.Credentials(
            accessToken: result.accessToken,
            refreshToken: result.refreshToken,
            expiresAt: result.expiresAt,
            scopes: creds.scopes,
            subscriptionType: creds.subscriptionType
        )
        try? CredentialStore.save(updated)
        return updated
    }

    private func fetchUsage(using creds: CredentialStore.Credentials) async throws -> Snapshot {
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
            throw ProbeError.unauthorized
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

        // 2026-06-15 정책: `limits` 배열이 정식 소스. 있으면 거기서, 없으면 레거시 키에서.
        let quotas: [Quota]
        if let limits = raw["limits"] as? [[String: Any]], !limits.isEmpty {
            quotas = limits.compactMap(Self.parseLimit)
        } else {
            quotas = Self.parseLegacyQuotas(raw)
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

    /// `limits` 배열의 한 항목을 Quota로. percent는 정수/실수 모두 허용.
    private static func parseLimit(_ obj: [String: Any]) -> Quota? {
        guard let kind = obj["kind"] as? String else { return nil }
        guard let percent = (obj["percent"] as? Double)
            ?? (obj["percent"] as? Int).map(Double.init) else { return nil }

        let group = Quota.Group(rawValue: (obj["group"] as? String) ?? "") ?? .other
        let severity = Quota.Severity(rawValue: (obj["severity"] as? String) ?? "") ?? .unknown
        let resetsAt = (obj["resets_at"] as? String).flatMap(Self.isoDate)
        let isActive = (obj["is_active"] as? Bool) ?? false

        var scopeLabel: String?
        if let scope = obj["scope"] as? [String: Any],
           let model = scope["model"] as? [String: Any],
           let name = model["display_name"] as? String {
            scopeLabel = name
        }

        let id = scopeLabel.map { "\(kind):\($0)" } ?? kind
        return Quota(
            id: id, group: group, kind: kind, scopeLabel: scopeLabel,
            utilization: percent, resetsAt: resetsAt,
            severity: severity, isActive: isActive
        )
    }

    /// 구버전 응답(또는 `limits` 누락) 폴백: 알려진 최상위 키를 Quota로 매핑.
    private static func parseLegacyQuotas(_ raw: [String: Any]) -> [Quota] {
        let legacy: [(key: String, kind: String, group: Quota.Group, scope: String?)] = [
            ("five_hour", "session", .session, nil),
            ("seven_day", "weekly_all", .weekly, nil),
            ("seven_day_opus", "weekly_scoped", .weekly, "Opus"),
            ("seven_day_sonnet", "weekly_scoped", .weekly, "Sonnet"),
            ("seven_day_omelette", "weekly_scoped", .weekly, "Design"),
        ]
        return legacy.compactMap { entry in
            guard let obj = raw[entry.key] as? [String: Any],
                  let utilization = obj["utilization"] as? Double else { return nil }
            let resetsAt = (obj["resets_at"] as? String).flatMap(Self.isoDate)
            let id = entry.scope.map { "\(entry.kind):\($0)" } ?? entry.kind
            return Quota(
                id: id, group: entry.group, kind: entry.kind, scopeLabel: entry.scope,
                utilization: utilization, resetsAt: resetsAt,
                severity: .unknown, isActive: false
            )
        }
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
