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
            Text(monitor.statusBarText)
        }
        .menuBarExtraStyle(.window)
    }
}
