# Validation of 1.6.0

Test date: 2026-10-07. Native GUI checks were performed on macOS 27.0 (26A428), Apple Silicon, with an app installed at `/Applications/Swift Quit.app` and its Accessibility grant enabled. Builds used Apple's Command Line Tools / Swift 6.4; no full Xcode installation was required.

## Automated and build checks

- 66 policy/evidence/close-intent regression checks: startup without windows, a full uninterrupted close delay, reappearing windows, unknown AX/CG evidence, pause/Space cancellation, one quit per transition, unsent-candidate restoration, CG visibility that cannot arm quitting, retained windows, and retirement of an old close intent when a window reopens.
- 36 preference checks with isolated disposable UserDefaults suites: upstream settings migration, mixed String/NSNumber values, inclusion/exclusion rules, spaces in paths, defaults, normalization, persistence, and delay bounds. No tests use the current user's preference domain.
- Swift package release compilation.
- Native and universal arm64/x86_64 app bundle compilation and strict signature verification for all architectures. Intel is compiled, not runtime-tested on this Apple Silicon machine.

## Observed GUI results

| Scenario | Observed result |
| --- | --- |
| TextEdit, last blank document closed with the red window button | Fresh AX count became zero; normal quit requested after approximately 2 seconds; TextEdit process exited. |
| Visual Studio Code (Electron), last window closed with the red window button | Brief on-screen CG record vetoed a transient zero result; after the record disappeared, normal quit requested after approximately 2 seconds; main Electron process exited. |
| TextEdit, only document minimized | Valid AX window retained despite no on-screen CG window; app stayed running beyond the close delay. |
| TextEdit, one minimized document plus one visible document; visible document closed | Minimized document remained a valid retained window; app stayed running. |
| Settings after the app's menu-bar icon was hidden | Reopening the installed app displayed Settings successfully. |
| Cmd-H with open TextEdit documents | App became hidden with valid AX windows; process remained running beyond the close delay. |
| Entering a full-screen Space with other apps on the previous desktop | Chrome, Docker Desktop and System Settings each temporarily reported AXWindows=0, while retainedAlive=1; all stayed running with onScreen=false. |
| Existing user preferences and login startup | Original exclusion list, hidden menu-bar preference and hidden startup retained; native login-item status reported enabled. |

Chrome remained running with an open window throughout the initial checks. That is a live-window retention check, not a last-window Chrome compatibility claim. The monitor's cross-Space protection is based on valid AX references to windows previously observed. Screen Recording access is neither requested nor used.

Local monitor logs include app identifiers, counts, process IDs and decisions. User window titles, file contents, and the user's preference list are not committed to this repository.

### Word follow-up (2026-10-08)

An existing exclusion rule prevented Microsoft Word from entering the monitor. After removing that rule through Settings, a fresh empty document created with Cmd-N was closed using its native red window button. No Cmd-Q was sent. AX and on-screen CG evidence became empty, Swift Quit requested normal termination approximately 2 seconds later, and an independent process query confirmed that Word's main process exited. Closing the Word start window was also checked and resulted in termination. This required a preference correction, not a change to the window-detection code.

GitHub Actions also passed all tests, Swift package release compilation, universal app construction and ZIP artifact upload on the macOS 15 runner: [build 37609361019](https://github.com/hechuyi/swiftquit/actions/runs/37609361019). Runtime compatibility was verified on the macOS 27 machine described above; the CI runner validates compilation and regressions.

## macOS 27 background attribution (2026-10-08)

A reported Ghostty “Running in Background” indicator was traced to detached local development processes that remained members of a Ghostty resource coalition, using read-only `launchctl print pid/<PID>` metadata. The Ghostty main process had already exited. An ordinary app termination request does not remove independently running descendant jobs. This is a different observation from a last-window failure: the main-app PID and attributed background jobs must both be inspected before diagnosing it.

`NSRunningApplication.terminate()` returning true means the request was successfully sent, not that termination has completed; completion requires an independent termination observation. See [Apple API documentation](https://developer.apple.com/documentation/appkit/nsrunningapplication/terminate()) and [macOS 27 background activity documentation](https://support.apple.com/en-au/125671). No user background jobs were terminated as part of that diagnosis.
