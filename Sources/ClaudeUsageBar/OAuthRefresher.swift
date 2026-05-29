import Foundation

/// 자체 저장된 refreshToken으로 Claude OAuth access token을 갱신한다.
///
/// 자체 PKCE 로그인(OAuthLogin)으로 발급받은 **독립 refresh token**을 사용하므로
/// Claude Code/Desktop의 토큰 회전과 충돌하지 않는다. 갱신 결과는 공유 Keychain이
/// 아니라 이 앱 전용 파일(CredentialStore)에만 저장된다.
struct OAuthRefresher {
    /// OAuth 상수는 ClaudeOAuth(OAuthLogin.swift)에서 단일 관리한다.
    /// authorize/exchange/refresh가 동일한 client_id·token 엔드포인트를 써야 한다.
    static var clientID: String { ClaudeOAuth.clientID }
    static var tokenURL: URL { ClaudeOAuth.tokenURL }

    struct Result {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Date
    }

    enum RefreshError: Error, LocalizedError {
        case noRefreshToken
        case invalidGrant            // refresh token 자체가 만료/무효 → 재로그인 필요
        case http(status: Int, body: String?)
        case network(Error)
        case parse(String)

        var errorDescription: String? {
            switch self {
            case .noRefreshToken:
                return "refresh token이 없습니다. 재로그인이 필요합니다."
            case .invalidGrant:
                return "refresh token이 만료되었습니다. 재로그인이 필요합니다."
            case .http(let status, let body):
                return "토큰 갱신 HTTP \(status): \(body?.prefix(200) ?? "")"
            case .network(let err):
                return "토큰 갱신 네트워크 오류: \(err.localizedDescription)"
            case .parse(let detail):
                return "토큰 갱신 응답 파싱 실패: \(detail)"
            }
        }
    }

    static func refresh(refreshToken: String, session: URLSession = .shared) async throws -> Result {
        guard !refreshToken.isEmpty else { throw RefreshError.noRefreshToken }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw RefreshError.network(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw RefreshError.parse("HTTPURLResponse 아님")
        }

        switch http.statusCode {
        case 200:
            break
        case 400, 401, 403:
            // invalid_grant / unauthorized_client 등 → 토큰으로는 회복 불가, 재로그인만이 답
            throw RefreshError.invalidGrant
        default:
            throw RefreshError.http(status: http.statusCode, body: String(data: data, encoding: .utf8))
        }

        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let access = json["access_token"] as? String, !access.isEmpty else {
            throw RefreshError.parse("access_token 없음")
        }

        // refresh token 회전: 응답에 새 값이 있으면 교체, 없으면 기존 값 유지
        let rotated = (json["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let newRefresh = rotated ?? refreshToken

        let expiresIn = (json["expires_in"] as? Double) ?? 3600
        let expiresAt = Date().addingTimeInterval(expiresIn)

        return Result(accessToken: access, refreshToken: newRefresh, expiresAt: expiresAt)
    }
}
