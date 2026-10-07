import AppKit

extension Notification.Name {
    static let swiftQuitSettingsChanged = Notification.Name("SwiftQuitSettingsChanged")
}

/// Preserve the upstream preference keys so an installed 1.5 keeps its rules.
final class Settings {
    static let shared = Settings()
    private let defaults: UserDefaults
    private var values: [String: String]
    private var paths: [String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        values = ["launchAtLogin": "false", "menubarIconEnabled": "true",
                  "launchHidden": "true", "closeDelay": "2", "excludeBehaviour": "excludeApps"]
        let stored = defaults.dictionary(forKey: "SwiftQuitSettings") ?? [:]
        let booleanKeys: Set<String> = ["launchAtLogin", "menubarIconEnabled", "launchHidden"]
        for (key, value) in stored {
            if let string = value as? String { values[key] = string }
            else if let number = value as? NSNumber {
                values[key] = booleanKeys.contains(key) ? String(number.boolValue) : number.stringValue
            }
        }
        paths = defaults.stringArray(forKey: "SwiftQuitExcludedApps") ?? []
    }

    private func set(_ key: String, _ value: String) {
        values[key] = value
        defaults.set(values, forKey: "SwiftQuitSettings")
        NotificationCenter.default.post(name: .swiftQuitSettingsChanged, object: self)
    }
    var launchAtLogin: Bool {
        get { values["launchAtLogin"] == "true" }
        set { set("launchAtLogin", String(newValue)) }
    }
    var menubarIconEnabled: Bool {
        get { values["menubarIconEnabled"] != "false" }
        set { set("menubarIconEnabled", String(newValue)) }
    }
    var launchHidden: Bool {
        get { values["launchHidden"] != "false" }
        set { set("launchHidden", String(newValue)) }
    }
    var closeDelay: Double {
        get { max(0.5, min(120, Double(values["closeDelay"] ?? "2") ?? 2)) }
        set { set("closeDelay", String(max(0.5, min(120, newValue.isFinite ? newValue : 2)))) }
    }
    var includeOnly: Bool {
        get { values["excludeBehaviour"] == "includeApps" }
        set { set("excludeBehaviour", newValue ? "includeApps" : "excludeApps") }
    }
    var applications: [String] {
        get { paths }
        set {
            paths = Array(Set(newValue.map { URL(fileURLWithPath: $0).standardizedFileURL.path })).sorted()
            defaults.set(paths, forKey: "SwiftQuitExcludedApps")
            NotificationCenter.default.post(name: .swiftQuitSettingsChanged, object: self)
        }
    }
    func shouldQuit(path: String) -> Bool {
        let present = paths.contains(URL(fileURLWithPath: path).standardizedFileURL.path)
        return includeOnly ? present : !present
    }
}
