import Foundation
import ServiceManagement

/// macOS 로그인 시 본 앱을 자동 시작하도록 등록/해제.
///
/// `SMAppService.mainApp`은 macOS 13+ 표준 API로, 별도 helper bundle 없이
/// 메인 앱 그 자체를 로그인 항목으로 등록한다. 사용자는 시스템 설정 →
/// 일반 → 로그인 항목에서도 동일하게 끄고 켤 수 있음.
///
/// 주의: `.app` 번들이 안정된 위치(예: `/Applications/`)에 있어야 한다.
/// build 디렉토리나 임시 위치에서 register하면 그 경로가 사라질 때 잘못된
/// 등록이 남을 수 있다.
enum LaunchAtLogin {
    /// 현재 로그인 항목 활성 여부.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 시스템 설정에서 추가 승인이 필요한 상태인지 (보안 강화 환경에서 발생).
    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// 등록/해제 토글. 성공 시 true 반환.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        let service = SMAppService.mainApp
        do {
            if enabled {
                guard service.status != .enabled else { return true }
                try service.register()
            } else {
                guard service.status == .enabled else { return true }
                try service.unregister()
            }
            return true
        } catch {
            NSLog("LaunchAtLogin: \(enabled ? "register" : "unregister") 실패 — \(error.localizedDescription)")
            return false
        }
    }
}
