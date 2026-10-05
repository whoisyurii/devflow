import SwiftUI
import AppKit
import UserNotifications

@main
struct DevFlowApp: App {
    @NSApplicationDelegateAdaptor(DevFlowDelegate.self) private var delegate
    @State private var model = BridgeModel.shared
    var body: some Scene {
        MenuBarExtra {
            Button("Open notch") { model.openIsland() }.keyboardShortcut("n")
            Text("\(model.active) active sessions · \(model.unread) unread")
            Divider()
            Button("Refresh Azure DevOps") { model.perform("refresh") }.disabled(model.busy || model.snapshot.connection == "disconnected")
            SettingsLink()
            Divider()
            Button("Quit DevFlow") { NSApp.terminate(nil) }.keyboardShortcut("q")
        } label: {
            Image(systemName: model.unread > 0 ? "bell.badge" : "arrow.triangle.branch")
        }
        SwiftUI.Settings { DevFlowSettingsView(model: model) }
    }
}

@MainActor
final class DevFlowDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var notch: IslandWindowController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        BridgeModel.shared.start()
        notch = IslandWindowController()
    }
    func applicationWillTerminate(_ notification: Notification) {
        notch?.stopMonitoring()
        BridgeModel.shared.stop()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.identifier
        await MainActor.run {
            let model = BridgeModel.shared
            if let entry = model.snapshot.activity.first(where: { $0.id == id }) { model.openActivity(entry) }
            else { model.openIsland(section: "activity") }
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner] }
}
