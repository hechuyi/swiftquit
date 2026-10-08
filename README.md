# Swift Quit — maintained fork

This fork of [onebadidea/swiftquit](https://github.com/onebadidea/swiftquit) fixes last-window quitting on modern macOS. It is maintained independently of the original author. The upstream v1.5 release still relies on Swindler's cached window-destruction events; this fork queries native Accessibility window state instead.

**Version 1.6.0 • macOS 13 or newer • Apple Silicon and Intel**

## Behavior

Close an application's last window to request a normal application quit after the configured delay (2 seconds by default). No force termination is used. Minimized windows and retained, valid windows on other Spaces count as open. Apps that have never been observed with a window are left running. Cmd-H does not mean close.

Include-only and exclusion lists, menu-bar visibility, hidden startup, launch at login, and configurable delay are supported. Existing `SwiftQuitSettings` and `SwiftQuitExcludedApps` preferences are preserved, using the original `onebadidea.Swift-Quit` bundle identifier. This is an upgrade of the installed app; running upstream and this fork simultaneously is unsupported.

Accessibility reads that time out or fail cancel a pending quit. Space changes and sleep/wake cancel pending work; Space transitions have a three-second grace period. A candidate is checked again immediately before requesting termination, including permissions, pause, rules, process identity, hidden state, and windows. A refused quit request is not repeatedly retried without observing a window again.

macOS 27 can retain dead WindowServer records. An all-Spaces CG window record alone therefore does not prove a live window. Retained AX window references protect known off-Space windows; on-screen CG windows veto transient zero-window AX results but never arm automatic quitting by themselves. Some apps hide/orderOut their window rather than destroy it: a recent click on that specific window's native close button can retire only that window after it ceases to be the main window. Other valid windows and minimized windows still veto quitting.

macOS 27 also reports ongoing background work in the Dock after a main app has exited. A terminal can remain marked “Running in Background” because a detached server, shell supervisor or other descendant still belongs to its resource coalition. Automatic application quitting leaves independently running background jobs intact. Their lifecycle and launch ownership need to be managed separately. See [Apple’s explanation](https://support.apple.com/en-au/125671).

The monitor uses public APIs and Accessibility access only, with no Screen Recording permission, private window-ID APIs, or network access. It favors keeping an app running when its window state is ambiguous. Custom drawn close controls and windows an app never exposes through Accessibility can require app-specific handling. The cross-Space protection applies to windows the monitor has observed; it cannot certify windows that were never exposed by the target application's AX implementation.

## Build and test

Install Apple's Command Line Tools (`xcode-select --install`) or Xcode. No Interface Builder compiler or third-party package is required.

```sh
./scripts/test.sh
./scripts/build.sh              # current machine's architecture
./scripts/build.sh build universal  # arm64 + x86_64
```

The app is generated at `build/Swift Quit.app`. `swift build -c release` also checks the Swift package, but the build script creates the required macOS app bundle. Source icons are in `Resources/AppIcon.iconset`; rebuild with `iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns`.

Local builds use normal ad-hoc signatures. A changed binary may require removing and re-adding the app in System Settings → Privacy & Security → Accessibility (called **Device Control & Data Access** in macOS 27). A Developer ID identity can be supplied with `SIGNING_IDENTITY`; notarization is a separate distribution step. CI compiles both architectures, runs policy/settings regressions, and uploads a ZIP artifact. The downloadable local build is ad-hoc signed, not Apple notarized.

## Install

Quit the existing Swift Quit, then replace the complete app bundle in `/Applications`. Do not merge app directories: leftover upstream resources invalidate the signature. Retain a copy of the old app if rollback is needed.

Launch the new app and renew its existing Accessibility permission if required. Permission state is shown in Settings; the app stays running and automatically starts monitoring after permission becomes available. Launch at login uses the native `SMAppService` registration and migrates the old helper only from a stable Applications installation. If macOS requests login-item approval, complete that in System Settings.

Reopen Swift Quit from Applications to display Settings, even when its menu-bar icon is hidden. The menu provides Pause/Resume. Local, size-limited diagnostics in `~/Library/Logs/Swift Quit/monitor.log` contain app identifiers, process IDs, counts, and quit decisions, never window titles or document contents.

## Maintenance and provenance

The original GPL-3.0 license is retained. Original work is by Johnny Baird and upstream contributors; original icons are credited to [Zabriskije](https://github.com/onebadidea/swiftquit/pull/31). This fork's native monitor and programmatic AppKit interface replace the old Storyboard/Xcode dependency chain, making builds reproducible with Command Line Tools alone.

Related upstream proposals: [#60](https://github.com/onebadidea/swiftquit/pull/60), [#62](https://github.com/onebadidea/swiftquit/pull/62), and [#64](https://github.com/onebadidea/swiftquit/pull/64). [TrueClose](https://github.com/nhatnam7kz/TrueClose) was studied as a behavioral reference, especially its delayed zero-window transition and Space grace period. No TrueClose source was copied; its repository did not declare a source license when reviewed.

See [VALIDATION.md](VALIDATION.md) for the tested environment and known scope. Further bug reports should specify macOS version, application/version, whether the window was minimized/on another Space/hidden, include or exclusion rules, and the relevant count/decision lines from the local log.
