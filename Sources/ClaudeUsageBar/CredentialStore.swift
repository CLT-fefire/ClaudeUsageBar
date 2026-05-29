import Foundation

/// OAuth 자격증명을 **이 앱 전용 파일**에 저장한다.
/// 경로: `~/.config/ClaudeUsageBar/credentials.json` (파일 0600 / 디렉토리 0700)
///
/// 과거에는 Claude Code/Desktop이 만든 Keychain 항목("Claude Code-credentials")을
/// 직접 읽고 write-back 했는데, 그 항목의 소유자(Anthropic 팀)와 다른 팀 서명인 이
/// 앱이 항목을 수정하면서 Keychain ACL이 churn → Claude 본체에 재인증 팝업이
/// 동시 다발로 뜨는 문제가 있었다. 이제 자체 PKCE 로그인(OAuthLogin)으로 받은
/// **독립 토큰**을 이 파일에만 저장하므로 공유 Keychain 항목을 일절 건드리지 않는다.
struct CredentialStore {

    struct Credentials: Codable, Equatable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Date?
        let scopes: [String]
        let subscriptionType: String?

        var hasRefreshToken: Bool { !refreshToken.isEmpty }
    }

    enum LoadError: Error, LocalizedError {
        case notSignedIn
        case parseError(String)

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                return "로그인이 필요합니다. 메뉴에서 'Claude 로그인'을 눌러주세요."
            case .parseError(let detail):
                return "자격증명 파일 파싱 실패: \(detail)"
            }
        }
    }

    // MARK: - Paths

    private static var directoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ClaudeUsageBar", isDirectory: true)
    }

    private static var fileURL: URL {
        directoryURL.appendingPathComponent("credentials.json")
    }

    // MARK: - Read

    /// 로그인 여부 빠른 확인 (파일 존재 + 파싱 가능).
    static var isSignedIn: Bool {
        (try? load()) != nil
    }

    static func load() throws -> Credentials {
        guard let data = try? Data(contentsOf: fileURL) else {
            throw LoadError.notSignedIn
        }
        do {
            return try decoder.decode(Credentials.self, from: data)
        } catch {
            throw LoadError.parseError(error.localizedDescription)
        }
    }

    // MARK: - Write

    static func save(_ credentials: Credentials) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        let data = try encoder.encode(credentials)
        try data.write(to: fileURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    static func delete() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Codec

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
