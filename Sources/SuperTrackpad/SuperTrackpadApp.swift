import SwiftUI
import AppKit
import Combine
import OSLog

@main
struct HandyToolbeltApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Window("HandyToolbelt", id: "main") {
            ProductivityView(host: delegate.host, trackpad: delegate.host.trackpad, windows: delegate.host.windows)
                .background(MainWindowPresenceReader())
        }
        .defaultSize(width: MainWindowLayout.width, height: MainWindowLayout.defaultHeight)
        .windowResizability(.contentSize)
        .commands { HandyToolbeltCommands(host: delegate.host, mainWindow: delegate.mainWindow) }
    }
}

private struct HandyToolbeltCommands: Commands {
    @ObservedObject var host: ProductivityModel
    let mainWindow: MainWindowAccess
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        let _ = mainWindow.register { [openWindow] in openWindow(id: "main") }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { reveal(.settings) }.keyboardShortcut(",")
            Button("Restart HandyToolbelt", action: host.restart).disabled(host.isRestarting)
        }
        CommandGroup(replacing: .newItem) {
            Button("New Gesture") { host.trackpad.addBinding(); reveal(.trackpad) }.keyboardShortcut("n")
        }
    }
    private func reveal(_ section: ProductivitySection) {
        host.section = section; mainWindow.open(); NSApp.activate(ignoringOtherApps: true)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let host = ProductivityModel()
    let mainWindow = MainWindowAccess(presence: .shared)
    private var statusItem: StatusItemController?
    private var restartSubscription: AnyCancellable?
    private var loginLaunch = false
    private var initialLaunchComplete = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        loginLaunch = LoginLaunchPolicy.isLoginItemLaunch(event: NSAppleEventManager.shared().currentAppleEvent)
        MainWindowPresence.shared.suppressesLaunchWindow = loginLaunch
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        !loginLaunch && !LoginLaunchPolicy.isLoginItemLaunch(event: NSAppleEventManager.shared().currentAppleEvent)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        loginLaunch = loginLaunch || LoginLaunchPolicy.isLoginItemLaunch(event: NSAppleEventManager.shared().currentAppleEvent)
        if loginLaunch { MainWindowPresence.shared.suppressRestoredLaunchWindow() }
        Logger(subsystem: "local.SuperTrackpad", category: "Relaunch").notice("Application finished launching")
        statusItem = StatusItemController(host: host) { [weak self] section in
            guard let self else { return }
            self.host.section = section
            self.mainWindow.open()
            NSApp.activate(ignoringOtherApps: true)
        }
        restartSubscription = host.$isRestarting.removeDuplicates().dropFirst().sink { [weak self] restarting in
            guard let self, !restarting else { return }
            if self.loginLaunch && !self.initialLaunchComplete {
                // Also cover a main window restored by SwiftUI during launch.
                MainWindowPresence.shared.suppressRestoredLaunchWindow()
            } else {
                self.mainWindow.open()
                NSApp.activate(ignoringOtherApps: true)
            }
            self.initialLaunchComplete = true
        }
        host.startAfterRelaunch(presentsWindow: !loginLaunch)
    }
    func applicationWillTerminate(_ notification: Notification) { statusItem = nil; host.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { mainWindow.open() }
        return true
    }
}
