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
        let scopeLabel: String?  // scope의 model·surface 표시명 (예: "Fable", "Cowork")
        let utilization: Double  // 0~100 (서버가 이미 0~100 스케일로 반환)
        let resetsAt: Date?
        let severity: Severity   // 서버 판정 심각도 (색상에 우선 반영)
        let isActive: Bool       // 현재 적용 중인 제한인지
        /// 주간 전체 한도 대비 비중. 모델별 주간 한도(`weekly_scoped`)에만 온다.
        var weeklyShare: WeeklyShare? = nil

        var percentUsed: Int { Int(utilization.rounded()) }

        /// `weekly_scoped_shares`의 한 항목. 모델별 한도는 주간 전체의 일부를 따로 떼어
        /// 준 것이라 "Fable 59%"만으로는 주간 전체에서 얼마를 쓴 건지 알 수 없다.
        /// 문서화되지 않은 필드라 **필드명에서 읽은 의미**다(관측 예: 할당 50,
        /// 사용 30, 해당 한도 59% ≈ 30/50).
        struct WeeklyShare: Hashable {
            let allowancePercent: Int   // 주간 전체 중 이 한도에 할당된 몫
            let usedPercent: Int        // 주간 전체 기준으로 이 한도가 쓴 몫
        }

        /// id만 바꾼 복제본. `ForEach`가 Identifiable을 쓰므로 중복 id는 렌더 붕괴다.
        fileprivate func withID(_ newID: String) -> Quota {
            Quota(id: newID, group: group, kind: kind, scopeLabel: scopeLabel,
                  utilization: utilization, resetsAt: resetsAt,
                  severity: severity, isActive: isActive, weeklyShare: weeklyShare)
        }

        fileprivate func with(weeklyShare share: WeeklyShare) -> Quota {
            var copy = self
            copy.weeklyShare = share
            return copy
        }

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

    /// 최소 단위(minor unit) + 지수로 오는 금액. `{amount_minor: 350, exponent: 2}` = 3.50.
    struct Money: Hashable {
        let amount: Double
        let currencyCode: String
    }

    /// 추가 사용량(크레딧) 요약. 서버가 `spend`(크레딧 지출)와 `extra_usage`(월 한도)로
    /// 나눠 주는 값을 표시용 한 줄로 합친 것. **둘 다 꺼져 있고 쓴 금액도 0이면 nil** —
    /// 아무 일도 없는 계정에 빈 줄을 띄우지 않도록 파서 경계에서 걸러낸다.
    struct Credits: Hashable {
        let isEnabled: Bool
        let used: Money?
        let limit: Money?
        let percent: Int?
        let severity: Quota.Severity
        let limitReached: Bool
    }

    struct Snapshot {
        let quotas: [Quota]
        let subscriptionType: String?
        let credits: Credits?
        let capturedAt: Date

        var session: Quota? { quotas.first { $0.group == .session } }

        /// 서버가 "지금 실제로 걸려 있다"고 표시한 한도. 세션 %가 낮아도 주간·모델별
        /// 한도가 먼저 닿을 수 있어, 화면이 그쪽을 가리키도록 따로 뽑는다.
        ///
        /// 서버가 둘 이상을 active로 줄 수 있다고 보고 **세션이 아닌 쪽 중 가장 많이 찬
        /// 것**을 고른다 — 응답 순서상 첫 항목(대개 세션)을 집으면 메뉴바가 세션 %만
        /// 보여주게 되어 이 값을 뽑는 이유가 사라진다.
        var activeQuota: Quota? {
            let active = quotas.filter(\.isActive)
            return active.filter { $0.group != .session }.max { $0.utilization < $1.utilization }
                ?? active.first
        }
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

    /// 검증 하네스가 픽스처를 실제 파서에 통과시킬 수 있도록 internal.
    static func parseResponse(_ data: Data, subscriptionType: String?) throws -> Snapshot {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProbeError.parse("응답이 JSON 객체 아님")
        }

        // 2026-06-15 정책: `limits` 배열이 정식 소스. 있으면 거기서, 없으면 레거시 키에서.
        let quotas: [Quota]
        if let limits = raw["limits"] as? [[String: Any]], !limits.isEmpty {
            // `weekly_scoped_shares`는 `limits`의 **원본 인덱스**로 대상을 가리킨다.
            // compactMap으로 먼저 걸러내면 인덱스가 밀려 엉뚱한 한도에 붙는다.
            let shares = Self.parseWeeklyShares(raw["weekly_scoped_shares"])
            quotas = limits.enumerated().compactMap { index, obj in
                guard let quota = Self.parseLimit(obj) else { return nil }
                return shares[index].map(quota.with(weeklyShare:)) ?? quota
            }
        } else {
            quotas = Self.parseLegacyQuotas(raw)
        }

        return Snapshot(
            quotas: Self.uniqued(quotas),
            subscriptionType: subscriptionType,
            credits: Self.parseCredits(raw),
            capturedAt: Date()
        )
    }

    /// 같은 id가 두 번 나오면 순번을 붙인다. 서버가 라벨 없는 동종 limit을 둘 이상 주는
    /// 경우(scope가 통째로 null인 `weekly_scoped` 2건 등)에 대한 최후 방어선.
    private static func uniqued(_ quotas: [Quota]) -> [Quota] {
        var counts: [String: Int] = [:]
        return quotas.map { q in
            let n = (counts[q.id] ?? 0) + 1
            counts[q.id] = n
            return n == 1 ? q : q.withID("\(q.id)#\(n)")
        }
    }

    /// `limit_index` → 주간 대비 비중. 두 값이 모두 0~100 범위일 때만 받는다 —
    /// 형태가 다르면 추측해서 그리지 않는다.
    private static func parseWeeklyShares(_ value: Any?) -> [Int: Quota.WeeklyShare] {
        guard let list = value as? [[String: Any]] else { return [:] }
        var out: [Int: Quota.WeeklyShare] = [:]
        for item in list {
            guard let index = item["limit_index"] as? Int,
                  let allowance = doubleValue(item["allowance_percent_of_weekly"]),
                  let used = doubleValue(item["used_percent_of_weekly"]),
                  (0...100).contains(allowance), (0...100).contains(used) else { continue }
            out[index] = Quota.WeeklyShare(allowancePercent: Int(allowance.rounded()),
                                           usedPercent: Int(used.rounded()))
        }
        return out
    }

    /// `spend` + `extra_usage`를 표시용 요약으로. 표시할 게 없으면 nil.
    private static func parseCredits(_ raw: [String: Any]) -> Credits? {
        let spend = raw["spend"] as? [String: Any]
        let extra = raw["extra_usage"] as? [String: Any]

        let spendEnabled = (spend?["enabled"] as? Bool) ?? false
        let extraEnabled = (extra?["is_enabled"] as? Bool) ?? false
        // `extra_usage.monthly_limit`은 단위가 문서화돼 있지 않아 쓰지 않는다.
        // 금액은 형태가 확인된 `spend`의 minor-unit 객체에서만 읽는다.
        let usedRaw = money(spend?["used"])
        let limit = money(spend?["limit"])
        let limitReached = (extra?["spend_limit_reached"] as? Bool) ?? false

        // 서버는 `spend`가 꺼진 계정에도 `used: 0` / `percent: 0`을 **채워서** 보낸다.
        // 그래서 ⓐ `??` 폴백을 쓰면 extra_usage 쪽 utilization이 영원히 가려지고,
        // ⓑ 0원을 금액으로 표시하면 그 소진율이 화면에서 밀려난다.
        // → 비율은 **켜져 있는 쪽**에서만, 금액은 **0이 아닐 때만** 쓴다.
        let spendPercent = spendEnabled ? doubleValue(spend?["percent"]) : nil
        let extraPercent = extraEnabled ? doubleValue(extra?["utilization"]) : nil
        let percent = spendPercent ?? extraPercent
        let used = (usedRaw?.amount ?? 0) > 0 ? usedRaw : nil

        guard spendEnabled || extraEnabled || limitReached || (usedRaw?.amount ?? 0) > 0 else {
            return nil
        }
        return Credits(
            isEnabled: spendEnabled || extraEnabled,
            used: used,
            limit: limit,
            percent: percent.map { Int($0.rounded()) },
            severity: Quota.Severity(rawValue: (spend?["severity"] as? String) ?? "") ?? .unknown,
            limitReached: limitReached
        )
    }

    /// `{amount_minor, currency, exponent}` 형태만 받는다. 형태가 다르면 nil —
    /// 단위를 추측해서 금액을 잘못 표시하는 것보다 안 보여주는 편이 낫다.
    /// **`exponent`도 필수다**: 기본값 2로 가정하면 소수 자리가 없는 통화(JPY·KRW)에서
    /// 금액이 100배 작게 표시된다. 유한한 범위의 값만 통과시킨다.
    private static func money(_ value: Any?) -> Money? {
        guard let dict = value as? [String: Any],
              let minor = doubleValue(dict["amount_minor"]), minor.isFinite,
              let exponent = doubleValue(dict["exponent"]),
              exponent >= 0, exponent <= 6,
              let code = dict["currency"] as? String, !code.isEmpty else { return nil }
        return Money(amount: minor / pow(10, exponent), currencyCode: code)
    }

    /// `limits` 배열의 한 항목을 Quota로. percent는 정수/실수 모두 허용.
    private static func parseLimit(_ obj: [String: Any]) -> Quota? {
        guard let kind = obj["kind"] as? String else { return nil }
        guard let percent = doubleValue(obj["percent"]) else { return nil }

        let group = Quota.Group(rawValue: (obj["group"] as? String) ?? "") ?? .other
        let severity = Quota.Severity(rawValue: (obj["severity"] as? String) ?? "") ?? .unknown
        let resetsAt = (obj["resets_at"] as? String).flatMap(Self.isoDate)
        let isActive = (obj["is_active"] as? Bool) ?? false

        // scope는 model / surface 두 축이고 각각 null일 수 있다. surface만 있는 limit
        // (예: Cowork)을 무시하면 id가 kind만으로 만들어져 같은 kind의 다른 limit과
        // 충돌한다 — 라벨도 잃고 목록도 깨진다.
        var axes: [(label: String?, key: String)] = []
        if let scope = obj["scope"] as? [String: Any] {
            if let axis = scopeAxis(scope["model"]) { axes.append(axis) }
            if let axis = scopeAxis(scope["surface"]) { axes.append(axis) }
        }
        let labels = axes.compactMap(\.label)
        let scopeLabel = labels.isEmpty ? nil : labels.joined(separator: " · ")
        let id = axes.isEmpty ? kind : "\(kind):\(axes.map(\.key).joined(separator: "/"))"
        return Quota(
            id: id, group: group, kind: kind, scopeLabel: scopeLabel,
            utilization: percent, resetsAt: resetsAt,
            severity: severity, isActive: isActive
        )
    }

    /// 구버전 응답(또는 `limits` 누락) 폴백: 알려진 최상위 키를 Quota로 매핑.
    private static func parseLegacyQuotas(_ raw: [String: Any]) -> [Quota] {
        // 응답에는 `tangelo`·`nimbus_quill` 같은 내부 코드네임 키도 섞여 오는데
        // 사람이 읽을 라벨이 없어 일부러 매핑하지 않는다(정식 소스인 `limits` 배열에는
        // 표시 대상이면 kind/scope와 함께 실려 온다).
        let legacy: [(key: String, kind: String, group: Quota.Group, scope: String?)] = [
            ("five_hour", "session", .session, nil),
            ("seven_day", "weekly_all", .weekly, nil),
            ("seven_day_opus", "weekly_scoped", .weekly, "Opus"),
            ("seven_day_sonnet", "weekly_scoped", .weekly, "Sonnet"),
            ("seven_day_omelette", "weekly_scoped", .weekly, "Fable"),
            ("seven_day_cowork", "weekly_scoped", .weekly, "Cowork"),
            ("seven_day_oauth_apps", "weekly_scoped", .weekly, "OAuth 앱"),
        ]
        return legacy.compactMap { entry in
            guard let obj = raw[entry.key] as? [String: Any],
                  let utilization = doubleValue(obj["utilization"]) else { return nil }
            let resetsAt = (obj["resets_at"] as? String).flatMap(Self.isoDate)
            let id = entry.scope.map { "\(entry.kind):\($0)" } ?? entry.kind
            return Quota(
                id: id, group: entry.group, kind: entry.kind, scopeLabel: entry.scope,
                utilization: utilization, resetsAt: resetsAt,
                severity: .unknown, isActive: false
            )
        }
    }

    /// scope 축 하나 → (표시 라벨, 식별자 조각). 서버는 `{id, display_name}` 객체로
    /// 주지만 문자열로 줄여 줄 수도 있어 둘 다 받는다.
    ///
    /// **`id`를 라벨로 승격하지 않는다.** 레거시 테이블이 일부러 배제한 내부 코드네임
    /// (`tangelo` 등)이 display_name 없이 오면 그대로 UI에 새기 때문이다. 라벨은 없어도
    /// (kind 기본 라벨로 떨어짐) 식별자에는 반영해 id 충돌만 막는다.
    private static func scopeAxis(_ value: Any?) -> (label: String?, key: String)? {
        if let s = value as? String, !s.isEmpty { return (s, s) }
        guard let dict = value as? [String: Any] else { return nil }
        let name = (dict["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let id = (dict["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        guard let key = name ?? id else { return nil }
        return (name, key)
    }

    /// 숫자 필드는 서버가 정수/실수를 섞어 주므로 한 곳에서 받아넘긴다.
    private static func doubleValue(_ value: Any?) -> Double? {
        (value as? Double) ?? (value as? Int).map(Double.init)
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
