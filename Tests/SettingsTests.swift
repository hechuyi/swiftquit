import AppKit

@main
struct SettingsTests {
    private static var checks = 0

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        checks += 1
        guard condition() else {
            fputs("FAIL: \(message) at \(file):\(line)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        // Never use .standard: these tests must not alter the installed app's
        // launch preferences or inclusion/exclusion list.
        let suiteName = "SwiftQuit.Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["launchAtLogin": "true", "menubarIconEnabled": "false",
                      "excludeBehaviour": "excludeApps", "futureSetting": "preserved"],
                     forKey: "SwiftQuitSettings")
        defaults.set(["/Applications/Microsoft Word.app", "/Users/test/Desktop/Space Game.app"],
                     forKey: "SwiftQuitExcludedApps")

        let migrated = Settings(defaults: defaults)
        expect(migrated.launchAtLogin, "legacy login preference survives migration")
        expect(!migrated.menubarIconEnabled, "legacy menu preference survives migration")
        expect(migrated.launchHidden, "missing launchHidden receives its default")
        expect(migrated.closeDelay == 2, "missing delay receives its default")
        expect(!migrated.includeOnly, "legacy exclusion mode survives migration")
        expect(!migrated.shouldQuit(path: "/Applications/Microsoft Word.app"), "excluded path containing spaces stays protected")
        expect(!migrated.shouldQuit(path: "/Users/test/Desktop/Space Game.app"), "user app path containing spaces stays protected")
        expect(migrated.shouldQuit(path: "/Applications/TextEdit.app"), "unlisted app remains eligible in exclusion mode")

        migrated.closeDelay = 3.5
        migrated.launchHidden = false
        let stored = defaults.dictionary(forKey: "SwiftQuitSettings") as? [String: String]
        expect(stored?["futureSetting"] == "preserved", "unknown upstream settings survive a write")
        expect(stored?["launchAtLogin"] == "true", "writing one setting preserves existing preferences")
        expect(stored?["closeDelay"] == "3.5", "delay is persisted")
        expect(stored?["launchHidden"] == "false", "new setting is persisted")

        migrated.includeOnly = true
        expect(migrated.shouldQuit(path: "/Applications/Microsoft Word.app"), "listed app is eligible in inclusion mode")
        expect(!migrated.shouldQuit(path: "/Applications/TextEdit.app"), "unlisted app stays protected in inclusion mode")
        migrated.applications = ["/Applications/Some Folder/../Microsoft Word.app",
                                 "/Applications/Microsoft Word.app",
                                 "/Users/test/Desktop/Space Game.app"]
        expect(migrated.applications.count == 2, "standardized duplicate paths are removed")
        expect(migrated.shouldQuit(path: "/Applications/Subfolder/../Microsoft Word.app"), "equivalent standardized path matches rule")

        let reloaded = Settings(defaults: defaults)
        expect(reloaded.closeDelay == 3.5 && !reloaded.launchHidden, "new settings survive reload")
        expect(reloaded.includeOnly && reloaded.launchAtLogin && !reloaded.menubarIconEnabled,
               "all existing settings survive reload")
        expect(reloaded.applications == migrated.applications, "rules survive reload")

        migrated.applications = []
        expect(!migrated.shouldQuit(path: "/Applications/TextEdit.app"), "empty inclusion list quits no apps")
        migrated.includeOnly = false
        expect(migrated.shouldQuit(path: "/Applications/TextEdit.app"), "empty exclusion list allows apps")

        migrated.closeDelay = -1
        expect(migrated.closeDelay == 0.5, "negative delay is clamped")
        migrated.closeDelay = 1000
        expect(migrated.closeDelay == 120, "excessive delay is clamped")
        migrated.closeDelay = .infinity
        expect(migrated.closeDelay == 2, "non-finite delay uses a safe default")
        migrated.closeDelay = .nan
        expect(migrated.closeDelay == 2, "NaN delay uses a safe default")

        defaults.set(["closeDelay": "invalid"], forKey: "SwiftQuitSettings")
        expect(Settings(defaults: defaults).closeDelay == 2, "invalid persisted delay uses a safe default")

        // Native defaults bindings may write CFBoolean/NSNumber beside the
        // upstream string keys. One native value must not discard the entire
        // dictionary and silently turn an inclusion list into exclusions.
        defaults.set(["launchAtLogin": NSNumber(value: true),
                      "menubarIconEnabled": NSNumber(value: false),
                      "launchHidden": NSNumber(value: false),
                      "closeDelay": NSNumber(value: 4.5),
                      "excludeBehaviour": "includeApps",
                      "futureSetting": "mixedPreserved"] as [String: Any],
                     forKey: "SwiftQuitSettings")
        defaults.set(["/Applications/Microsoft Word.app"], forKey: "SwiftQuitExcludedApps")
        let mixed = Settings(defaults: defaults)
        expect(mixed.launchAtLogin, "native Boolean login preference stays enabled")
        expect(!mixed.menubarIconEnabled, "native Boolean menu preference stays disabled")
        expect(!mixed.launchHidden, "native Boolean hidden-launch preference stays disabled")
        expect(mixed.closeDelay == 4.5, "native numeric delay stays 4.5 seconds")
        expect(mixed.includeOnly, "mixed-type dictionary must preserve original inclusion mode")
        expect(mixed.shouldQuit(path: "/Applications/Microsoft Word.app"), "mixed migration preserves listed eligible app")
        expect(!mixed.shouldQuit(path: "/Applications/TextEdit.app"), "mixed migration protects unlisted apps from accidental quitting")
        mixed.closeDelay = 6
        let mixedReloaded = Settings(defaults: defaults)
        expect(mixedReloaded.includeOnly && mixedReloaded.launchAtLogin && !mixedReloaded.menubarIconEnabled,
               "writing migrated settings preserves inclusion mode and native Boolean choices")
        expect(mixedReloaded.closeDelay == 6, "mixed migrated delay persists after writing")
        expect((defaults.dictionary(forKey: "SwiftQuitSettings")?["futureSetting"] as? String) == "mixedPreserved",
               "mixed migration preserves other original string keys")
        print("Settings regressions passed (\(checks) checks, isolated defaults suite)")
    }
}
