import Foundation
import SwiftUI
import AppKit

@MainActor
final class UsageMonitor: ObservableObject {
    @Published private(set) var snapshot: ClaudeUsageProbe.Snapshot?
    @Published private(set) var lastError: String?
    @Published private(set) var isProbing: Bool = false
    @Published private(set) var lastUpdated: Date = .distantPast

    /// 로컬 로그 기반 사용량(공식 API와 별개). 차트가 켜져 있을 때만 채워진다.
    @Published private(set) var localUsage: LocalUsageReader.Data?
    @Published private(set) var isScanningLocal: Bool = false

    /// status.claude.com 서비스 상태. 인증과 무관하게 폴링한다.
    @Published private(set) var status: StatusProbe.Snapshot?
    /// 직전 상태 조회가 실패했는지. 마지막 스냅샷은 유지하되 stale임을 UI에 알린다.
    @Published private(set) var statusFailed: Bool = false
    /// 진행 중인 상태 조회. 새 요청이 오면 **이전 것을 취소**한다(last-wins).
    ///
    /// 불린 플래그 + 세대 카운터 조합을 두 번 시도했다가 걷어냈다 — 가드 소유권이
    /// `refreshStatus`의 defer와 `setStatusEnabled` 양쪽으로 쪼개지면서, 폐기된 옛
    /// 태스크의 defer가 **현재 태스크가 살아있는 채로** 가드를 풀어버렸다. 그러면
    /// 같은 요청이 둘 동시에 뜨고 응답 순서가 뒤집혀 옛 스냅샷이 새것을 덮어쓴다
    /// (= 진행 중 장애가 화면에서 사라짐). 취소는 소유권이 Task 하나에 모여 있어
    /// 이 계열의 경쟁이 구조적으로 성립하지 않는다.
    private var statusTask: Task<Void, Never>?

    /// 상태 폴링 on/off. 앱이 사용자 모르게 외부 호스트를 계속 두드리지 않도록
    /// 끌 수단을 준다. 뷰의 @AppStorage와 같은 UserDefaults 키를 공유한다.
    static let showServiceStatusKey = "showServiceStatus"
    private var isStatusEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.showServiceStatusKey) as? Bool ?? true
    }

    /// 토글이 바뀌었을 때 뷰가 호출. 켜면 즉시 1회 조회 + 타이머 재개, 끄면 정지·초기화.
    func setStatusEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.showServiceStatusKey)
        // 진행 중이던 조회를 취소해 뒤늦은 응답이 꺼진 기능을 되살리지 못하게 한다.
        statusTask?.cancel()
        statusTask = nil

        guard enabled else {
            statusTimer?.invalidate()
            statusTimer = nil
            status = nil
            statusFailed = false
            return
        }
        scheduleStatus()
        refreshStatus()
    }

    /// 차트 on/off 플래그. 뷰의 @AppStorage와 같은 UserDefaults 키를 공유한다.
    static let showLocalChartKey = "showLocalChart"
    private var isLocalChartEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.showLocalChartKey)
    }

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

    /// 상태 페이지 폴링은 사용량 주기(기본 60분)와 분리한다. 응답이 2KB대라
    /// 5분 간격이어도 트래픽이 무시할 수준이고, 장애는 빨리 알아야 의미가 있다.
    private let statusProbe = StatusProbe()
    private var statusTimer: Timer?
    private static let statusInterval: TimeInterval = 5 * 60

    // 진행 중인 PKCE 로그인 흐름의 상태(코드 교환 시 필요).
    private var pendingVerifier: String?
    private var pendingState: String?

    init() {
        let stored = UserDefaults.standard.object(forKey: Self.intervalKey) as? Int
        self.refreshIntervalSeconds = stored ?? Self.defaultInterval
        self.isAuthenticated = CredentialStore.isSignedIn

        // 상태 폴링은 인증 여부와 무관 — 로그인 화면에서도 장애를 보여준다.
        // 타이머를 **먼저** 건다: 첫 조회가 타임아웃(10s)까지 늘어져도 주기 폴링 시작이
        // 그만큼 밀리지 않도록.
        if isStatusEnabled {
            scheduleStatus()
            refreshStatus()
        }

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
        if isLocalChartEnabled { refreshLocalUsage() }
    }

    func manualRefresh() {
        Task { @MainActor in
            await refresh()
        }
        refreshStatus()
    }

    /// status.claude.com 조회를 시작한다. 실패해도 사용량 UI를 방해하지 않도록
    /// 에러를 삼키고 마지막 스냅샷을 유지한 채 `statusFailed` 플래그만 세운다.
    ///
    /// **last-wins**: 진행 중이던 조회를 취소하고 새로 띄운다. 수동 새로고침(⌘R)과
    /// 5분 타이머가 겹쳐도 살아남는 요청이 하나뿐이라, 먼저 출발한 느린 응답이
    /// 나중에 도착해 새 스냅샷을 옛것으로 덮어쓰는 경로가 생기지 않는다.
    func refreshStatus() {
        statusTask?.cancel()
        guard isStatusEnabled else {
            statusTask = nil
            return
        }
        statusTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await self.statusProbe.probe()
                // URLSession은 취소 시 CancellationError가 아니라 URLError(.cancelled)를
                // 던지므로, 성공 경로에서도 취소 여부를 직접 본다.
                guard !Task.isCancelled, self.isStatusEnabled else { return }
                self.status = snapshot
                self.statusFailed = false
            } catch {
                guard !Task.isCancelled, self.isStatusEnabled else { return }
                self.statusFailed = true
            }
        }
    }

    /// 로컬 로그를 백그라운드 스레드에서 스캔해 `localUsage`를 갱신.
    /// 무거운 콜드 스캔도 메인 액터를 막지 않도록 detached로 돌린다.
    func refreshLocalUsage() {
        guard !isScanningLocal else { return }
        isScanningLocal = true
        Task { [weak self] in
            let data = await Task.detached(priority: .utility) {
                LocalUsageReader.scan()
            }.value
            guard let self else { return }
            self.localUsage = data
            self.isScanningLocal = false
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
    }

    /// 고정 주기 반복 타이머. 사용량 타이머와 달리 `isAuthenticated` 에 걸리지 않고
    /// 로그아웃/재로그인에도 살아있어야 하므로 `handleSessionExpired()` 에서 건드리지 않는다.
    private func scheduleStatus() {
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: Self.statusInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshStatus()
            }
        }
    }

    private func scheduleNext() {
        guard isAuthenticated else { return }
        let interval = TimeInterval(max(60, refreshIntervalSeconds))
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
