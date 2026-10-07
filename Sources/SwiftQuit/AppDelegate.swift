import AppKit
import ApplicationServices
import ServiceManagement
import Carbon

enum LoginItemSupport {
    /// Register a stable installed bundle, never a development build directory.
    static var isInstalledApplication: Bool {
        let url = Bundle.main.bundleURL.standardizedFileURL
        guard url.pathExtension == "app" else { return false }
        let userApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true).path + "/"
        return url.path.hasPrefix("/Applications/") || url.path.hasPrefix(userApplications)
    }
}

@main
enum SwiftQuitMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.setActivationPolicy(.accessory)
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var pauseItem: NSMenuItem!
    private var statusTimer: Timer?
    private var settingsObserver: NSObjectProtocol?
    private lazy var settingsWindow = SettingsWindowController()
    private var didFinishLaunching = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleReopenAppleEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEReopenApplication)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeApplicationMenu()
        makeStatusMenu()
        migrateLoginItem()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .swiftQuitSettingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshMenu()
            self?.settingsWindow.reloadSettings()
        }
        WindowMonitor.shared.start()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshMenu()
            self?.settingsWindow.refreshStatus()
        }
        didFinishLaunching = true
        refreshMenu()
        if !Settings.shared.launchHidden || !AXIsProcessTrusted() {
            openSettings(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusTimer?.invalidate()
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        WindowMonitor.shared.stop()
        NSAppleEventManager.shared().removeEventHandler(
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEReopenApplication)
        )
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings(nil)
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard didFinishLaunching else { return }
        openSettings(nil)
    }

    @objc private func handleReopenAppleEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        openSettings(nil)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    private func migrateLoginItem() {
        let marker = "SwiftQuitLoginItemMigrationVersion"
        guard LoginItemSupport.isInstalledApplication,
              UserDefaults.standard.integer(forKey: marker) < 1 else { return }
        if Settings.shared.launchAtLogin {
            do {
                if SMAppService.mainApp.status == .notRegistered {
                    try SMAppService.mainApp.register()
                }
            } catch {
                NSLog("Swift Quit could not migrate launch at login: %@", error.localizedDescription)
                return
            }
        }
        // The identifier is verified against the original v1.5 helper's Info.plist.
        SMLoginItemSetEnabled("onebadidea.Swift-Quit-LaunchAtLoginHelper" as CFString, false)
        UserDefaults.standard.set(1, forKey: marker)
    }

    private func makeApplicationMenu() {
        let root = NSMenu()
        let appMenu = NSMenu(title: "Swift Quit")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        root.addItem(appItem)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Swift Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        NSApp.mainMenu = root
    }

    private func makeStatusMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Swift Quit")
        icon?.isTemplate = true
        statusItem.button?.image = icon
        let menu = NSMenu()
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        pauseItem = NSMenuItem(title: "Pause Automatic Quitting", action: #selector(togglePause(_:)), keyEquivalent: "")
        pauseItem.target = self
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Swift Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func refreshMenu() {
        statusItem.isVisible = Settings.shared.menubarIconEnabled
        pauseItem.title = WindowMonitor.shared.isPaused ? "Resume Automatic Quitting" : "Pause Automatic Quitting"
        let state = !AXIsProcessTrusted() ? "Accessibility permission required" :
            WindowMonitor.shared.isPaused ? "Paused" : "Automatic quitting active"
        statusItem.button?.toolTip = "Swift Quit — \(state)"
    }

    @objc private func openSettings(_ sender: Any?) {
        settingsWindow.reloadSettings()
        settingsWindow.showWindow(sender)
        settingsWindow.window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func togglePause(_ sender: Any?) {
        WindowMonitor.shared.isPaused.toggle()
        refreshMenu()
        settingsWindow.refreshStatus()
    }
}
