import SwiftUI
import AppKit

@main
struct ClaudeUsageBarApp: App {
    @StateObject private var monitor = UsageMonitor()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(monitor: monitor)
        } label: {
            Text(monitor.statusBarText)
        }
        .menuBarExtraStyle(.window)
    }
}
