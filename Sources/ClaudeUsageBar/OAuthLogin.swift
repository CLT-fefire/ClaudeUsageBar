import Foundation
import CryptoKit
import Security

/// Claude OAuth 공통 상수. Claude Code의 공개(public) PKCE 클라이언트를 그대로
/// 사용한다. client_id는 모든 Claude Code 설치가 공유하는 공개값이라 비밀이 아니다.
///
/// 중요: 이 앱은 Claude Code/Desktop이 쓰는 Keychain 항목("Claude Code-credentials")을
/// 절대 건드리지 않는다. 자체 PKCE 로그인으로 **독립된** refresh token을 발급받아
/// 자체 파일(CredentialStore)에만 저장한다. 덕분에 공유 Keychain 항목의 ACL을
/// 망가뜨려 Claude 본체에 재인증 팝업을 유발하던 문제가 원천적으로 사라진다.
enum ClaudeOAuth {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let authorizeURL = URL(string: "https://claude.ai/oauth/authorize")!
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let redirectURI = "https://platform.claude.com/oauth/code/callback"
    static let scopes = ["user:profile", "user:inference"]
}

/// PKCE(S256) Authorization Code 흐름으로 Claude에 직접 로그인한다.
///
/// 흐름:
/// 1. `makeAuthorization()` 으로 verifier/state/authorize URL 생성 → 브라우저 오픈
/// 2. 사용자가 Claude 로그인 후 콜백 페이지에 표시되는 코드("code#state")를 복사
/// 3. `exchange(code:verifier:state:)` 로 코드를 토큰으로 교환
enum OAuthLogin {

    struct Authorization {
        let url: URL
        let verifier: String
        let state: String
    }

    struct Tokens {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Date
        let scopes: [String]
        let subscriptionType: String?
    }

    enum LoginError: Error, LocalizedError {
        case stateMismatch
        case http(status: Int, body: String?)
        case network(Error)
        case parse(String)

        var errorDescription: String? {
            switch self {
            case .stateMismatch:
                return "OAuth state 불일치. 다시 시도하세요."
            case .http(let status, let body):
                return "토큰 교환 HTTP \(status): \(body?.prefix(200) ?? "")"
            case .network(let err):
                return "네트워크 오류: \(err.localizedDescription)"
            case .parse(let detail):
                return "응답 파싱 실패: \(detail)"
            }
        }
    }

    /// authorize URL과 PKCE 상태값을 생성한다. 호출자는 verifier/state를 보관했다가
    /// `exchange`에 그대로 넘겨야 한다.
    static func makeAuthorization() -> Authorization {
        let verifier = randomURLSafeToken()
        let challenge = codeChallenge(for: verifier)
        let state = randomURLSafeToken()

        var components = URLComponents(url: ClaudeOAuth.authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: ClaudeOAuth.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: ClaudeOAuth.redirectURI),
            URLQueryItem(name: "scope", value: ClaudeOAuth.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]
        return Authorization(url: components.url!, verifier: verifier, state: state)
    }

    /// 콜백 코드를 토큰으로 교환한다. `rawCode`는 "code" 또는 "code#state" 형식 모두 허용.
    static func exchange(
        rawCode: String,
        verifier: String,
        state: String,
        session: URLSession = .shared
    ) async throws -> Tokens {
        let trimmed = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "#", maxSplits: 1)
        let code = String(parts.first ?? "")
        if parts.count > 1, String(parts[1]) != state {
            throw LoginError.stateMismatch
        }

        var request = URLRequest(url: ClaudeOAuth.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let body: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "state": state,
            "client_id": ClaudeOAuth.clientID,
            "redirect_uri": ClaudeOAuth.redirectURI,
            "code_verifier": verifier
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LoginError.network(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw LoginError.parse("HTTPURLResponse 아님")
        }
        guard http.statusCode == 200 else {
            throw LoginError.http(status: http.statusCode, body: String(data: data, encoding: .utf8))
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let access = json["access_token"] as? String, !access.isEmpty else {
            throw LoginError.parse("access_token 없음")
        }

        let refresh = (json["refresh_token"] as? String) ?? ""
        let expiresIn = (json["expires_in"] as? Double) ?? 3600
        let scopeStr = (json["scope"] as? String) ?? ClaudeOAuth.scopes.joined(separator: " ")
        let account = json["account"] as? [String: Any]
        let subscription = (account?["subscription_type"] as? String)
            ?? (json["subscription_type"] as? String)

        return Tokens(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(expiresIn),
            scopes: scopeStr.split(separator: " ").map(String.init),
            subscriptionType: subscription
        )
    }

    // MARK: - PKCE Helpers

    /// 32바이트 난수를 base64url로 인코딩한 토큰. code_verifier / state 양쪽에 사용.
    private static func randomURLSafeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URLEncode(Data(bytes))
    }

    private static func codeChallenge(for verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Data(hash))
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
