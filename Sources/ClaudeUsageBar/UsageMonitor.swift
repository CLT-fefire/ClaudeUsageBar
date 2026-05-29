import Foundation
import SwiftUI
import AppKit

@MainActor
final class UsageMonitor: ObservableObject {
    @Published private(set) var snapshot: ClaudeUsageProbe.Snapshot?
    @Published private(set) var lastError: String?
    @Published private(set) var isProbing: Bool = false
    @Published private(set) var lastUpdated: Date = .distantPast
    @Published private(set) var nextRefreshAt: Date = .distantFuture

    /// 자체 PKCE 로그인 기반 인증 상태. 자격증명 파일 존재 여부로 결정.
    @Published private(set) var isAuthenticated: Bool
    /// 로그인 흐름에서 브라우저를 열고 사용자 코드 입력을 기다리는 중인지.
    @Published private(set) var isAwaitingCode: Bool = false
    /// 로그인 흐름 전용 에러 메시지(usage 조회 에러 lastError와 분리).
    @Published private(set) var loginError: String?

    /// 사용자가 선택한 갱신 주기 (초). UI에서 5분/15분/30분/60분 중 선택.
    /// 값이 바뀌면 즉시 타이머 재스케줄.
    @Published var refreshIntervalSeconds: Int {
        didSet {
            UserDefaults.standard.set(refreshIntervalSeconds, forKey: Self.intervalKey)
            scheduleNext()
        }
    }

    static let availableIntervals: [Int] = [5 * 60, 15 * 60, 30 * 60, 60 * 60]
    private static let intervalKey = "refreshIntervalSeconds"
    private static let defaultInterval = 60 * 60   // 60분

    private let probe = ClaudeUsageProbe()
    private var timer: Timer?

    // 진행 중인 PKCE 로그인 흐름의 상태(코드 교환 시 필요).
    private var pendingVerifier: String?
    private var pendingState: String?

    init() {
        let stored = UserDefaults.standard.object(forKey: Self.intervalKey) as? Int
        self.refreshIntervalSeconds = stored ?? Self.defaultInterval
        self.isAuthenticated = CredentialStore.isSignedIn

        guard isAuthenticated else { return }
        Task { @MainActor in
            await refresh()
            scheduleNext()
        }
    }

    // 의도적으로 deinit 없음. UsageMonitor는 앱 라이프타임 @StateObject로
    // 앱 종료 시까지 살아있으므로 Timer 정리가 불필요하다. Swift 6 strict
    // concurrency에선 nonisolated deinit에서 MainActor-isolated Timer 접근이
    // 금지라 deinit을 두면 컴파일 에러 발생.

    var statusBarText: String {
        if !isAuthenticated { return "로그인" }
        if isProbing && snapshot == nil { return "…" }
        guard let session = snapshot?.session else { return "—" }
        return "\(session.percentUsed)%"
    }

    func refresh() async {
        guard isAuthenticated else { return }
        isProbing = true
        defer { isProbing = false }
        do {
            let snap = try await probe.probe()
            snapshot = snap
            lastError = nil
        } catch ClaudeUsageProbe.ProbeError.notSignedIn,
                ClaudeUsageProbe.ProbeError.reauthRequired {
            // 자격증명이 없거나 refresh token이 죽음 → 로그인 화면으로 전환
            handleSessionExpired()
            return
        } catch {
            lastError = error.localizedDescription
        }
        lastUpdated = Date()
    }

    func manualRefresh() {
        Task { @MainActor in
            await refresh()
        }
    }

    // MARK: - Auth

    /// 브라우저로 Claude 로그인 페이지를 열고 코드 입력 대기 상태로 전환.
    func startLogin() {
        let auth = OAuthLogin.makeAuthorization()
        pendingVerifier = auth.verifier
        pendingState = auth.state
        loginError = nil
        isAwaitingCode = true
        NSWorkspace.shared.open(auth.url)
    }

    /// 콜백 페이지에서 복사한 코드("code" 또는 "code#state")로 토큰을 교환.
    func submitCode(_ rawCode: String) {
        guard let verifier = pendingVerifier, let state = pendingState else {
            loginError = "진행 중인 로그인이 없습니다. 다시 시작하세요."
            return
        }
        let trimmed = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            loginError = "코드를 입력하세요."
            return
        }
        Task { @MainActor in
            do {
                let tokens = try await OAuthLogin.exchange(
                    rawCode: trimmed, verifier: verifier, state: state
                )
                try CredentialStore.save(
                    CredentialStore.Credentials(
                        accessToken: tokens.accessToken,
                        refreshToken: tokens.refreshToken,
                        expiresAt: tokens.expiresAt,
                        scopes: tokens.scopes,
                        subscriptionType: tokens.subscriptionType
                    )
                )
                isAuthenticated = true
                isAwaitingCode = false
                loginError = nil
                pendingVerifier = nil
                pendingState = nil
                await refresh()
                scheduleNext()
            } catch {
                loginError = error.localizedDescription
            }
        }
    }

    /// 로그인 흐름 취소(코드 입력 화면 → 초기 화면).
    func cancelLogin() {
        isAwaitingCode = false
        loginError = nil
        pendingVerifier = nil
        pendingState = nil
    }

    /// 로그아웃: 자체 자격증명 파일 삭제 + 상태 초기화.
    func signOut() {
        CredentialStore.delete()
        handleSessionExpired()
    }

    private func handleSessionExpired() {
        timer?.invalidate()
        timer = nil
        isAuthenticated = false
        snapshot = nil
        lastError = nil
        nextRefreshAt = .distantFuture
    }

    private func scheduleNext() {
        guard isAuthenticated else { return }
        let interval = TimeInterval(max(60, refreshIntervalSeconds))
        nextRefreshAt = Date().addingTimeInterval(interval)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.refresh()
                self.scheduleNext()
            }
        }
    }
}
