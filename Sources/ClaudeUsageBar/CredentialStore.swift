import Foundation
import Security

/// macOS Keychain의 "Claude Code-credentials" Generic Password 항목에서
/// OAuth 토큰을 읽어온다.
///
/// Claude Code/Claude Desktop이 로그인 시 이 항목을 만들어두며,
/// 토큰 갱신도 그 쪽에서 자동으로 해주기 때문에 본 앱은 읽기만 한다.
/// 첫 실행 시 macOS가 "ClaudeUsageBar가 Keychain 정보에 접근?" 프롬프트를
/// 띄우는데, "항상 허용"을 선택하면 그 후로는 무음 통과.
struct CredentialStore {
    static let serviceName = "Claude Code-credentials"

    struct Credentials {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Date?
        let subscriptionType: String?
        let organizationUuid: String?
    }

    enum LoadError: Error, LocalizedError {
        case itemNotFound
        case keychainError(OSStatus)
        case parseError(String)

        var errorDescription: String? {
            switch self {
            case .itemNotFound:
                return "Keychain에서 Claude Code 자격증명을 찾을 수 없습니다. Claude Desktop 또는 'claude' CLI에서 로그인하세요."
            case .keychainError(let code):
                return "Keychain 접근 실패 (code \(code)). 'ClaudeUsageBar의 Keychain 접근 허용'을 체크했는지 확인하세요."
            case .parseError(let detail):
                return "자격증명 형식 파싱 실패: \(detail)"
            }
        }
    }

    static func load() throws -> Credentials {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            throw LoadError.itemNotFound
        default:
            throw LoadError.keychainError(status)
        }

        guard let data = item as? Data else {
            throw LoadError.parseError("Keychain 항목이 Data 아님")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LoadError.parseError("JSON 파싱 실패")
        }
        guard let oauth = json["claudeAiOauth"] as? [String: Any] else {
            throw LoadError.parseError("claudeAiOauth 키 없음")
        }
        guard let accessToken = oauth["accessToken"] as? String,
              !accessToken.isEmpty else {
            throw LoadError.parseError("accessToken 비어있음")
        }
        let refreshToken = (oauth["refreshToken"] as? String) ?? ""

        var expiresAt: Date?
        if let ms = oauth["expiresAt"] as? Double {
            expiresAt = Date(timeIntervalSince1970: ms / 1000.0)
        }

        return Credentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            subscriptionType: oauth["subscriptionType"] as? String,
            organizationUuid: json["organizationUuid"] as? String
        )
    }

    /// 갱신된 토큰을 Keychain에 다시 써넣는다.
    ///
    /// Anthropic OAuth는 refresh 시 refresh token도 회전(rotation)시키므로,
    /// 우리가 갱신했으면 반드시 write-back 해야 Keychain의 refresh token이
    /// 최신으로 유지된다. 그러지 않으면 Claude Code/Desktop 본체가 옛
    /// refresh token으로 갱신을 시도하다 로그인이 깨질 수 있다.
    ///
    /// 기존 항목 전체 JSON을 읽어 토큰 3개 필드만 교체하고 나머지(scopes,
    /// subscriptionType, rateLimitTier 등)는 그대로 보존한다.
    static func save(accessToken: String, refreshToken: String, expiresAt: Date) throws {
        let readQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(readQuery as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw LoadError.keychainError(status)
        }
        guard var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var oauth = json["claudeAiOauth"] as? [String: Any] else {
            throw LoadError.parseError("write-back: 기존 JSON 파싱 실패")
        }

        oauth["accessToken"] = accessToken
        oauth["refreshToken"] = refreshToken
        // expiresAt은 epoch milliseconds (Claude Code가 쓰는 형식과 동일)
        oauth["expiresAt"] = Int((expiresAt.timeIntervalSince1970 * 1000).rounded())
        json["claudeAiOauth"] = oauth

        let newData = try JSONSerialization.data(withJSONObject: json)
        let matchQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName
        ]
        let attributes: [String: Any] = [kSecValueData as String: newData]
        let updateStatus = SecItemUpdate(matchQuery as CFDictionary, attributes as CFDictionary)
        guard updateStatus == errSecSuccess else {
            throw LoadError.keychainError(updateStatus)
        }
    }
}
