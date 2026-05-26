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
}
