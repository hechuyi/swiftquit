import AppKit
import ApplicationServices

/// Independent implementation using public AX APIs. Never infer closure merely
/// from a window being absent from the CURRENT Space's WindowServer list.
final class WindowMonitor {
    static let shared = WindowMonitor()
    private let worker = DispatchQueue(label: "onebadidea.Swift-Quit.window-scan", qos: .utility)
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var clickMonitor: Any?
    private var polling = false
    private var epoch = 0
    private var quietUntil: TimeInterval = 0
    private var sleeping = false
    private var lastTrusted = false
    private var buttons: [CloseButton] = [] // main thread only
    private var states: [pid_t: State] = [:] // serial worker only
    private var paused = false

    var isPaused: Bool {
        get { paused }
        set {
            guard paused != newValue else { return }
            paused = newValue
            invalidate(reason: newValue ? "paused" : "resumed")
        }
    }

    private struct Identity: Equatable {
        let pid: pid_t
        let path: String
        let bundleID: String
        let launchDate: Date?
    }
    private struct Candidate { let identity: Identity; let hidden: Bool; let frontmost: Bool }
    private struct CloseIntent {
        let window: AXUIElement
        let time: TimeInterval
        var lifecycle = CloseIntentLifecycle()
    }
    private struct CloseButton {
        let identity: Identity
        let window: AXUIElement
        let rect: CGRect // AX coordinates, origin at top left of the main display
        let sampledAt: TimeInterval
    }
    private struct State {
        let identity: Identity
        var windows: [AXUIElement] = []
        var policy = QuitPolicy()
        var intent: CloseIntent?
        var lastDiagnostic = ""
    }
    private struct Inspection {
        let observation: QuitPolicy.Observation
        let windows: [AXUIElement]
        let closeButtons: [CloseButton]
        let allowsHiddenQuit: Bool
        let summary: String
    }
    private enum Attribute {
        case value(CFTypeRef)
        case absent
        case destroyed
        case unknown
    }

    func start() {
        guard timer == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                             object: nil, queue: .main) { [weak self] _ in
            self?.quietUntil = ProcessInfo.processInfo.systemUptime + 3
            self?.invalidate(reason: "Space changed")
        })
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification,
                                             object: nil, queue: .main) { [weak self] _ in
            self?.sleeping = true
            self?.invalidate(reason: "sleep")
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification,
                                             object: nil, queue: .main) { [weak self] _ in
            self?.sleeping = false
            self?.quietUntil = ProcessInfo.processInfo.systemUptime + 3
            self?.invalidate(reason: "wake")
        })
        observers.append(NotificationCenter.default.addObserver(forName: .swiftQuitSettingsChanged,
                                                                object: nil, queue: .main) { [weak self] _ in
            self?.invalidate(reason: "rules changed")
        })
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.recordCloseClick(event)
        }
        timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        timer?.tolerance = 0.1
        RunLoop.main.add(timer!, forMode: .common)
        MonitorLog.write("started version=1.6.0")
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        invalidate(reason: "stopped")
    }

    /// Keep retained AX windows through a Space change. Valid windows on another
    /// Space must continue vetoing a quit, even if AXWindows temporarily omits them.
    private func invalidate(reason: String) {
        epoch += 1
        buttons = []
        worker.async {
            for pid in Array(self.states.keys) {
                self.states[pid]?.policy.cancelPending()
                self.states[pid]?.intent = nil
            }
        }
        MonitorLog.write(reason)
    }

    private func eligible(_ app: NSRunningApplication) -> Bool {
        guard app.activationPolicy == .regular, app.isFinishedLaunching, !app.isTerminated,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let path = app.bundleURL?.path else { return false }
        let protected = ["com.apple.finder", "com.apple.Spotlight", "com.apple.notificationcenterui", "com.apple.loginwindow"]
        return !protected.contains(app.bundleIdentifier ?? "") && Settings.shared.shouldQuit(path: path)
    }
    private func identity(_ app: NSRunningApplication) -> Identity? {
        guard let path = app.bundleURL?.path else { return nil }
        return Identity(pid: app.processIdentifier, path: path,
                        bundleID: app.bundleIdentifier ?? app.localizedName ?? "unknown", launchDate: app.launchDate)
    }

    private func poll() {
        let trusted = AXIsProcessTrusted()
        if trusted != lastTrusted {
            lastTrusted = trusted
            invalidate(reason: "Accessibility trusted=\(trusted)")
        }
        guard timer != nil, trusted, !paused, !sleeping,
              ProcessInfo.processInfo.systemUptime >= quietUntil, !polling else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let candidates = NSWorkspace.shared.runningApplications.filter(eligible).compactMap { app -> Candidate? in
            guard let id = identity(app) else { return nil }
            return Candidate(identity: id, hidden: app.isHidden, frontmost: id.pid == frontmost)
        }
        let currentEpoch = epoch
        let delay = Settings.shared.closeDelay
        polling = true
        worker.async {
            let pids = Set(candidates.map { $0.identity.pid })
            self.states = self.states.filter { pids.contains($0.key) }
            var newButtons: [CloseButton] = []
            for candidate in candidates {
                let id = candidate.identity
                var state = self.states[id.pid] ?? State(identity: id)
                if state.identity != id { state = State(identity: id) }
                let inspection = self.inspect(candidate, state: state, delay: delay)
                state.windows = inspection.windows
                newButtons += inspection.closeButtons
                if inspection.summary != state.lastDiagnostic {
                    state.lastDiagnostic = inspection.summary
                    MonitorLog.write("\(id.bundleID) pid=\(id.pid) \(inspection.summary)")
                }
                if state.intent?.lifecycle.observe(inspection.observation) == true {
                    state.intent = nil // a reopened window retires the old red-click intent
                }
                let shouldQuit = state.policy.observe(inspection.observation,
                    at: ProcessInfo.processInfo.systemUptime, delay: delay,
                    suspended: candidate.hidden && !inspection.allowsHiddenQuit)
                self.states[id.pid] = state
                if shouldQuit { self.finalize(candidate, state: state, delay: delay, epoch: currentEpoch) }
            }
            let finishedButtons = newButtons
            DispatchQueue.main.async {
                self.polling = false
                if self.epoch == currentEpoch { self.buttons = finishedButtons }
            }
        }
    }

    private func read(_ element: AXUIElement, _ name: String) -> Attribute {
        AXUIElementSetMessagingTimeout(element, 0.15)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        switch error {
        case .success: return value.map(Attribute.value) ?? .absent
        case .noValue, .attributeUnsupported: return .absent
        case .invalidUIElement: return .destroyed
        default: return .unknown
        }
    }
    private func frame(_ element: AXUIElement) -> CGRect? {
        guard case .value(let position) = read(element, kAXPositionAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(),
              case .value(let size) = read(element, kAXSizeAttribute),
              CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: origin, size: dimensions)
    }
    private func same(_ a: AXUIElement, _ b: AXUIElement) -> Bool { CFEqual(a, b) }

    /// On-screen windows are a TRANSIENT veto against an AX enumeration race.
    /// optionAll cannot veto closure: macOS 27 retains dead WindowServer records.
    /// Other Spaces are protected by retained AX references instead.
    private func hasOnScreenWindow(_ pid: pid_t) -> Bool? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        return windows.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? NSNumber, let height = bounds["Height"] as? NSNumber,
                  width.doubleValue > 1, height.doubleValue > 1 else { return false }
            if let alpha = info[kCGWindowAlpha as String] as? NSNumber, alpha.doubleValue == 0 { return false }
            return true
        }
    }

    private func inspect(_ candidate: Candidate, state: State, delay: Double) -> Inspection {
        let id = candidate.identity
        let started = ProcessInfo.processInfo.systemUptime
        let axApp = AXUIElementCreateApplication(id.pid)
        guard case .value(let raw) = read(axApp, kAXWindowsAttribute),
              let current = raw as? [AXUIElement] else {
            return Inspection(observation: .unknown, windows: state.windows, closeButtons: [],
                              allowsHiddenQuit: false, summary: "AXWindows unknown; pending cancelled")
        }
        var windows = state.windows
        for window in current where !windows.contains(where: { same($0, window) }) { windows.append(window) }
        let onScreen = hasOnScreenWindow(id.pid)
        var alive: [AXUIElement] = []
        var newButtons: [CloseButton] = []
        var uncertain = onScreen == nil
        var ignoredCloseTarget = false
        let now = ProcessInfo.processInfo.systemUptime
        let intent = state.intent.flatMap { now - $0.time <= max(10, delay + 3) ? $0 : nil }
        let mainWindow = read(axApp, kAXMainWindowAttribute)
        if case .unknown = mainWindow { uncertain = true }
        if case .value(let value) = mainWindow, CFGetTypeID(value) == AXUIElementGetTypeID() {
            let main = value as! AXUIElement
            if !windows.contains(where: { same($0, main) }) { windows.append(main) }
        }
        for window in windows {
            if ProcessInfo.processInfo.systemUptime - started > 0.75 {
                return Inspection(observation: .unknown, windows: windows, closeButtons: [],
                                  allowsHiddenQuit: false, summary: "AX inspection budget exceeded; pending cancelled")
            }
            switch read(window, kAXRoleAttribute) {
            case .destroyed: continue
            case .unknown, .absent:
                uncertain = true
                alive.append(window)
                continue
            case .value(let role):
                guard (role as? String) == kAXWindowRole else { continue }
            }
            // Some Electron apps hide/orderOut the closed window instead of
            // destroying its AX object. Ignore ONLY the positively identified
            // close-button target, after main-window removal and no visible
            // WindowServer window. A minimize/Cmd-H/Space change is insufficient.
            if let intent, same(intent.window, window), onScreen == false,
               case .value(let minimized) = read(window, kAXMinimizedAttribute),
               (minimized as? NSNumber)?.boolValue == false {
                let mainRemoved: Bool
                switch mainWindow {
                case .absent, .destroyed: mainRemoved = true
                case .value:
                    // A different main window is positive evidence of a live
                    // window, even before AXWindows includes it.
                    mainRemoved = false
                case .unknown: mainRemoved = false
                }
                if mainRemoved { ignoredCloseTarget = true; continue }
            }
            alive.append(window)
            if candidate.frontmost, !candidate.hidden,
               case .value(let button) = read(window, kAXCloseButtonAttribute),
               CFGetTypeID(button) == AXUIElementGetTypeID(),
               let rect = frame(button as! AXUIElement), rect.width > 0, rect.height > 0 {
                newButtons.append(CloseButton(identity: id, window: window, rect: rect, sampledAt: now))
            }
        }
        let observation = WindowEvidence.observation(
            hasLiveAXWindow: !alive.isEmpty, onScreen: onScreen, uncertain: uncertain)
        // Keep even a hidden, clicked target until the final validation; other
        // retained windows are never suppressed by a close intent for this one.
        let tracked = ignoredCloseTarget ? windows : alive
        return Inspection(observation: observation, windows: tracked, closeButtons: newButtons,
            allowsHiddenQuit: candidate.hidden && ignoredCloseTarget && alive.isEmpty,
            summary: "AX=\(current.count) retainedAlive=\(alive.count) onScreen=\(onScreen.map(String.init) ?? "unknown") hidden=\(candidate.hidden) closeTarget=\(ignoredCloseTarget) unknown=\(uncertain)")
    }

    private func recordCloseClick(_ event: NSEvent) {
        guard !paused, !sleeping, AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication, eligible(app), let id = identity(app),
              let point = event.cgEvent?.location else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard let button = buttons.first(where: {
            $0.identity == id && now - $0.sampledAt < 1.5 && $0.rect.contains(point)
        }) else { return }
        let clickEpoch = epoch
        worker.async {
            // Serial ordering makes this visible to the next scan. An epoch
            // change clears the intent before any termination can be applied.
            guard var state = self.states[id.pid], state.identity == id else { return }
            state.intent = CloseIntent(window: button.window, time: now)
            state.policy.cancelPending()
            self.states[id.pid] = state
            DispatchQueue.main.async {
                if self.epoch == clickEpoch { MonitorLog.write("\(id.bundleID) red close button clicked") }
            }
        }
    }

    private func finalize(_ candidate: Candidate, state: State, delay: Double, epoch expectedEpoch: Int) {
        DispatchQueue.main.async {
            let id = candidate.identity
            guard self.timer != nil, !self.paused, !self.sleeping, self.epoch == expectedEpoch,
                  AXIsProcessTrusted(), ProcessInfo.processInfo.systemUptime >= self.quietUntil,
                  let app = NSRunningApplication(processIdentifier: id.pid),
                  self.eligible(app), self.identity(app) == id else {
                self.restoreUnsent(id)
                return
            }
            // AX calls happen on the worker for every regular scan. Only this
            // final, rare candidate check runs here, with bounded AX timeouts,
            // immediately before requesting a normal (never forced) termination.
            let fresh = self.inspect(Candidate(identity: id, hidden: app.isHidden, frontmost: false), state: state, delay: delay)
            guard case .noWindows = fresh.observation,
                  !app.isHidden || fresh.allowsHiddenQuit else {
                self.restoreUnsent(id)
                return
            }
            let accepted = app.terminate()
            MonitorLog.write("quit requested \(id.bundleID) pid=\(id.pid) accepted=\(accepted)")
            // Do not rearm on refusal or a cancelled save dialog. A newly
            // observed real window is required before another zero transition.
        }
    }
    private func restoreUnsent(_ id: Identity) {
        worker.async {
            guard self.states[id.pid]?.identity == id else { return }
            self.states[id.pid]?.policy.restoreUnsentCandidate()
        }
    }
}

/// Bounded local diagnostics contain process IDs/counts, never window titles.
private enum MonitorLog {
    private static let lock = NSLock()
    static func write(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return }
        let directory = library.appendingPathComponent("Logs/Swift Quit", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("monitor.log")
        if let size = (try? FileManager.default.attributesOfItem(atPath: path.path)[.size]) as? NSNumber,
           size.intValue > 1_000_000 {
            let previous = directory.appendingPathComponent("monitor.previous.log")
            try? FileManager.default.removeItem(at: previous)
            try? FileManager.default.moveItem(at: path, to: previous)
        }
        if !FileManager.default.fileExists(atPath: path.path) {
            FileManager.default.createFile(atPath: path.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: path) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        try? handle.write(contentsOf: Data(line.utf8))
    }
}
