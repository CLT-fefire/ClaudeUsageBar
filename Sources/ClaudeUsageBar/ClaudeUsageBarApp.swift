import SwiftUI
import AppKit

@main
struct ClaudeUsageBarApp: App {
    @StateObject private var monitor = UsageMonitor()
    @AppStorage("selectedTheme") private var selectedThemeRaw = ThemeID.liquidGlass.rawValue

    private var theme: Theme {
        (ThemeID(rawValue: selectedThemeRaw) ?? .liquidGlass).make()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(monitor: monitor)
                .environment(\.theme, theme)
                .appFontDesign(theme.bodyFontDesign)
                .appForeground(theme.palette.textPrimary)
                .preferredColorScheme(theme.forcesDark ? .dark : nil)
        } label: {
            // `isHealthy` 가 아니라 `hasOutage` 인 이유: 예정된 점검이나 미지 상태로
            // 경고가 뜨면 오탐이고, 오탐 한 번이 다음 진짜 경보의 신뢰를 깎는다.
            MenuBarLabel(
                text: monitor.statusBarText,
                hasOutage: monitor.status?.hasOutage == true
            )
        }
        .menuBarExtraStyle(.window)
    }
}
