import AppKit
import ApplicationServices
import ServiceManagement
import UniformTypeIdentifiers

final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let permissionStatus = NSTextField(labelWithString: "")
    private let permissionButton = NSButton(title: "Open System Settings…", target: nil, action: nil)
    private let pauseButton = NSButton(title: "Pause", target: nil, action: nil)
    private let loginSwitch = NSSwitch()
    private let menuSwitch = NSSwitch()
    private let hiddenSwitch = NSSwitch()
    private let loginStatus = NSTextField(wrappingLabelWithString: "")
    private let delayField = NSTextField(string: "2")
    private let modePopup = NSPopUpButton()
    private let applicationsTable = NSTableView()
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private var applications: [String] = []

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 690),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Swift Quit Settings"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        makeInterface()
        reloadSettings()
    }

    required init?(coder: NSCoder) { fatalError("Settings are created programmatically") }

    private func makeInterface() {
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        window!.contentView!.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: window!.contentView!.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: window!.contentView!.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: window!.contentView!.topAnchor, constant: 24),
            content.bottomAnchor.constraint(equalTo: window!.contentView!.bottomAnchor, constant: -24)
        ])

        let title = NSTextField(labelWithString: "Swift Quit")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        content.addArrangedSubview(title)
        let description = NSTextField(wrappingLabelWithString: "Quit an application after its last window closes.")
        description.textColor = .secondaryLabelColor
        content.addArrangedSubview(description)

        permissionStatus.font = .systemFont(ofSize: 13, weight: .medium)
        permissionButton.target = self
        permissionButton.action = #selector(openPrivacySettings(_:))
        pauseButton.target = self
        pauseButton.action = #selector(togglePause(_:))
        content.addArrangedSubview(row(permissionStatus, permissionButton, pauseButton))
        content.addArrangedSubview(separator())

        configure(loginSwitch, action: #selector(loginChanged(_:)))
        configure(menuSwitch, action: #selector(menuChanged(_:)))
        configure(hiddenSwitch, action: #selector(hiddenChanged(_:)))
        content.addArrangedSubview(row(NSTextField(labelWithString: "Launch at login"), loginSwitch))
        loginStatus.font = .systemFont(ofSize: 11)
        loginStatus.textColor = .secondaryLabelColor
        content.addArrangedSubview(loginStatus)
        content.addArrangedSubview(row(NSTextField(labelWithString: "Show menu bar icon"), menuSwitch))
        content.addArrangedSubview(row(NSTextField(labelWithString: "Keep settings hidden at launch"), hiddenSwitch))

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimum = 0.5
        formatter.maximum = 120
        formatter.maximumFractionDigits = 2
        delayField.formatter = formatter
        delayField.target = self
        delayField.action = #selector(delayChanged(_:))
        delayField.alignment = .right
        delayField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        content.addArrangedSubview(row(NSTextField(labelWithString: "Delay before quitting (seconds)"), delayField))
        content.addArrangedSubview(separator())

        modePopup.addItems(withTitles: ["All applications except these", "Only these applications"])
        modePopup.target = self
        modePopup.action = #selector(modeChanged(_:))
        content.addArrangedSubview(row(NSTextField(labelWithString: "Automatically quit"), modePopup))

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("application"))
        column.title = "Application"
        column.width = 550
        applicationsTable.addTableColumn(column)
        applicationsTable.headerView = nil
        applicationsTable.rowHeight = 28
        applicationsTable.dataSource = self
        applicationsTable.delegate = self
        applicationsTable.allowsMultipleSelection = true
        applicationsTable.setAccessibilityLabel("Application rules")
        let scroll = NSScrollView()
        scroll.documentView = applicationsTable
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 115).isActive = true
        content.addArrangedSubview(scroll)

        let add = NSButton(title: "Add Application…", target: self, action: #selector(addApplication(_:)))
        removeButton.target = self
        removeButton.action = #selector(removeApplication(_:))
        content.addArrangedSubview(row(add, removeButton))
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let footer = NSTextField(labelWithString: "Swift Quit \(version) · Community-maintained fork")
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        content.addArrangedSubview(footer)

        // Cross-view constraints need a common ancestor. Arrange every row first,
        // then give it the content width after it has joined the window hierarchy.
        for arrangedView in content.arrangedSubviews {
            arrangedView.translatesAutoresizingMaskIntoConstraints = false
            arrangedView.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
    }

    private func configure(_ control: NSSwitch, action: Selector) {
        control.target = self
        control.action = action
    }

    private func row(_ views: NSView...) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        for (index, view) in views.enumerated() {
            stack.addArrangedSubview(view)
            if index == 0 {
                let space = NSView()
                space.setContentHuggingPriority(.defaultLow, for: .horizontal)
                stack.addArrangedSubview(space)
            }
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    func reloadSettings() {
        let settings = Settings.shared
        menuSwitch.state = settings.menubarIconEnabled ? .on : .off
        hiddenSwitch.state = settings.launchHidden ? .on : .off
        delayField.doubleValue = settings.closeDelay
        modePopup.selectItem(at: settings.includeOnly ? 1 : 0)
        applications = settings.applications
        applicationsTable.reloadData()
        removeButton.isEnabled = applicationsTable.selectedRow >= 0
        refreshStatus()
    }

    func refreshStatus() {
        let trusted = AXIsProcessTrusted()
        permissionStatus.stringValue = trusted ?
            (WindowMonitor.shared.isPaused ? "Automatic quitting paused" : "Automatic quitting active") :
            "Accessibility permission required"
        permissionStatus.textColor = trusted ? .labelColor : .systemOrange
        pauseButton.title = WindowMonitor.shared.isPaused ? "Resume" : "Pause"
        pauseButton.isEnabled = trusted
        permissionButton.isHidden = trusted
        loginSwitch.isEnabled = LoginItemSupport.isInstalledApplication
        guard LoginItemSupport.isInstalledApplication else {
            loginSwitch.state = .off
            loginStatus.stringValue = "Install Swift Quit in Applications to enable launch at login."
            return
        }
        switch SMAppService.mainApp.status {
        case .enabled:
            loginSwitch.state = .on
            loginStatus.stringValue = "Enabled in System Settings."
        case .requiresApproval:
            loginSwitch.state = .on
            loginStatus.stringValue = "Approve Swift Quit in System Settings → General → Login Items."
        case .notFound:
            loginSwitch.state = .off
            loginStatus.stringValue = "Install Swift Quit in Applications to enable launch at login."
        case .notRegistered:
            loginSwitch.state = .off
            loginStatus.stringValue = "Disabled."
        @unknown default:
            loginSwitch.state = .off
            loginStatus.stringValue = "Login item status is unavailable."
        }
    }

    @objc private func loginChanged(_ sender: NSSwitch) {
        do {
            if sender.state == .on {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
            Settings.shared.launchAtLogin = sender.state == .on
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Could not change launch at login"
            alert.beginSheetModal(for: window!)
        }
        refreshStatus()
    }

    @objc private func menuChanged(_ sender: NSSwitch) { Settings.shared.menubarIconEnabled = sender.state == .on }
    @objc private func hiddenChanged(_ sender: NSSwitch) { Settings.shared.launchHidden = sender.state == .on }
    @objc private func modeChanged(_ sender: NSPopUpButton) { Settings.shared.includeOnly = sender.indexOfSelectedItem == 1 }
    @objc private func delayChanged(_ sender: NSTextField) {
        let delay = sender.doubleValue
        if delay.isFinite, (0.5...120).contains(delay) {
            Settings.shared.closeDelay = delay
        } else {
            sender.doubleValue = Settings.shared.closeDelay
        }
    }

    @objc private func openPrivacySettings(_ sender: Any?) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func togglePause(_ sender: Any?) {
        WindowMonitor.shared.isPaused.toggle()
        refreshStatus()
    }

    @objc private func addApplication(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "Choose Applications"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window!) { response in
            guard response == .OK else { return }
            var paths = Settings.shared.applications
            for url in panel.urls {
                let path = url.standardizedFileURL.path
                if !paths.contains(path) { paths.append(path) }
            }
            Settings.shared.applications = paths
        }
    }

    @objc private func removeApplication(_ sender: Any?) {
        let selected = applicationsTable.selectedRowIndexes
        Settings.shared.applications = applications.enumerated().compactMap { selected.contains($0.offset) ? nil : $0.element }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { applications.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: applications[row])
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = applications[row]
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeButton.isEnabled = applicationsTable.selectedRow >= 0
    }
}
