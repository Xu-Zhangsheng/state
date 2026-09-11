import AppKit
import SwiftUI
import smc_power

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let batteryService: BatteryService
    private unowned let runtime: StasisRuntime

    init(runtime: StasisRuntime, batteryService: BatteryService) {
        self.runtime = runtime
        self.batteryService = batteryService
        super.init()
    }

    func showSettings() {
        if let existingWindow = window {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView(
            runtime: runtime,
            batteryService: batteryService
        )
        let hostingController = NSHostingController(rootView: settingsView)

        let newWindow = NSWindow(contentViewController: hostingController)
        newWindow.title = String(localized: "state Settings")
        newWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        newWindow.center()
        newWindow.setFrameAutosaveName("SettingsWindow")
        newWindow.isReleasedWhenClosed = false
        newWindow.delegate = self
        newWindow.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)

        self.window = newWindow
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            window = nil
        }
    }
}
