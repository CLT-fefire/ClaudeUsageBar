import Foundation
import SwiftUI

@MainActor
final class UsageMonitor: ObservableObject {
    @Published private(set) var snapshot: ClaudeUsageProbe.Snapshot?
    @Published private(set) var lastError: String?
    @Published private(set) var isProbing: Bool = false
    @Published private(set) var lastUpdated: Date = .distantPast
    @Published private(set) var nextRefreshAt: Date = .distantFuture

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

    init() {
        let stored = UserDefaults.standard.object(forKey: Self.intervalKey) as? Int
        self.refreshIntervalSeconds = stored ?? Self.defaultInterval

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
        if isProbing && snapshot == nil { return "…" }
        guard let session = snapshot?.session else { return "—" }
        return "\(session.percentUsed)%"
    }

    func refresh() async {
        isProbing = true
        defer { isProbing = false }
        do {
            let snap = try await probe.probe()
            snapshot = snap
            lastError = nil
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

    private func scheduleNext() {
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
