import Foundation

@main
struct PolicyTests {
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
        expect(WindowEvidence.observation(hasLiveAXWindow: false, onScreen: true, uncertain: false) == .unknown,
               "CG visibility alone may veto a quit but cannot count as a live AX window")
        expect(WindowEvidence.observation(hasLiveAXWindow: true, onScreen: false, uncertain: false) == .windowsOpen,
               "a retained AX window on another Space or minimized must remain open")
        expect(WindowEvidence.observation(hasLiveAXWindow: true, onScreen: true, uncertain: false) == .windowsOpen,
               "a visible live AX window is positive evidence")
        expect(WindowEvidence.observation(hasLiveAXWindow: false, onScreen: false, uncertain: false) == .noWindows,
               "confirmed AX zero with no visible WindowServer window is closure evidence")
        expect(WindowEvidence.observation(hasLiveAXWindow: false, onScreen: false, uncertain: true) == .unknown,
               "failed AX reads cannot count as closure")
        expect(WindowEvidence.observation(hasLiveAXWindow: true, onScreen: false, uncertain: true) == .unknown,
               "a partial AX failure interrupts the zero-window interval")
        expect(WindowEvidence.observation(hasLiveAXWindow: false, onScreen: nil, uncertain: false) == .unknown,
               "failed WindowServer enumeration cannot count as closure")
        expect(WindowEvidence.observation(hasLiveAXWindow: true, onScreen: nil, uncertain: false) == .unknown,
               "missing WindowServer evidence remains uncertain even with a retained reference")

        // Reproduce the dangerous CG-only startup -> Space switch sequence.
        // No AX window was ever tracked, so changing Spaces cannot become a
        // last-window close event, even after the full configured delay.
        var untrackedSpace = QuitPolicy()
        _ = untrackedSpace.observe(WindowEvidence.observation(
            hasLiveAXWindow: false, onScreen: true, uncertain: false), at: 0, delay: 2)
        expect(!untrackedSpace.armed, "CG-only positive observation must never arm quitting")
        untrackedSpace.cancelPending()
        for time in [3.0, 5.0, 30.0] {
            expect(!untrackedSpace.observe(WindowEvidence.observation(
                hasLiveAXWindow: false, onScreen: false, uncertain: false), at: time, delay: 2),
                "moving an untracked window off-screen must not request quit")
        }

        var retainedSpace = QuitPolicy()
        _ = retainedSpace.observe(.windowsOpen, at: 0, delay: 2)
        _ = retainedSpace.observe(.noWindows, at: 1, delay: 2)
        for time in [2.0, 5.0, 30.0] {
            expect(!retainedSpace.observe(WindowEvidence.observation(
                hasLiveAXWindow: true, onScreen: false, uncertain: false), at: time, delay: 2),
                "a live off-Space or minimized window cancels a pending quit")
        }

        var closeAnimation = CloseIntentLifecycle()
        expect(!closeAnimation.observe(.windowsOpen), "live target during initial close animation keeps intent")
        expect(!closeAnimation.observe(.windowsOpen), "multiple animation samples do not retire intent")
        expect(!closeAnimation.sawClosure, "a live animation sample cannot confirm closure")
        expect(!closeAnimation.observe(.unknown), "uncertain animation sample cannot confirm closure")
        expect(!closeAnimation.observe(.noWindows), "first verified closure retains the clicked target intent")
        expect(closeAnimation.sawClosure, "verified closure is remembered")
        expect(!closeAnimation.observe(.noWindows), "continued closure keeps the target valid for final validation")
        expect(closeAnimation.observe(.windowsOpen), "reopened live window must retire the old red-click intent")

        var uncertainReopen = CloseIntentLifecycle()
        _ = uncertainReopen.observe(.noWindows)
        expect(!uncertainReopen.observe(.unknown), "AX uncertainty alone does not claim reopening")
        expect(uncertainReopen.sawClosure, "uncertainty preserves previously observed closure")
        expect(uncertainReopen.observe(.windowsOpen), "reopening after an AX failure still retires stale intent")

        // The engine clears the optional intent when observe returns true. A
        // later hide cannot resurrect this retired intent to authorize quitting.
        var staleIntent: CloseIntentLifecycle? = CloseIntentLifecycle()
        _ = staleIntent?.observe(.noWindows)
        if staleIntent?.observe(.windowsOpen) == true { staleIntent = nil }
        expect(staleIntent == nil, "close then reopen discards the old target before a subsequent Cmd-H")

        // An app that was already windowless when monitoring started is not a
        // close event. This also protects apps intended to stay in the menu bar.
        var startedEmpty = QuitPolicy()
        for time in [0.0, 2.0, 30.0, 300.0] {
            expect(!startedEmpty.observe(.noWindows, at: time, delay: 2),
                   "startup without a window must never request quit")
        }

        var closed = QuitPolicy()
        expect(!closed.observe(.windowsOpen, at: 10, delay: 2), "open window arms monitoring")
        expect(!closed.observe(.noWindows, at: 11, delay: 2), "first empty sample starts delay")
        expect(!closed.observe(.noWindows, at: 12.999, delay: 2), "full delay must elapse")
        expect(closed.observe(.noWindows, at: 13, delay: 2), "continuous empty interval requests quit")
        expect(!closed.observe(.noWindows, at: 15, delay: 2), "quit request must not repeat")
        expect(!closed.observe(.noWindows, at: 300, delay: 2), "a refused or cancelled quit must not loop")
        expect(!closed.observe(.windowsOpen, at: 301, delay: 2), "new window allows a new close event")
        expect(!closed.observe(.noWindows, at: 302, delay: 2), "new close event starts a new delay")
        expect(closed.observe(.noWindows, at: 304, delay: 2), "a later real close can quit again")

        var reopened = QuitPolicy()
        _ = reopened.observe(.windowsOpen, at: 0, delay: 2)
        _ = reopened.observe(.noWindows, at: 1, delay: 2)
        expect(!reopened.observe(.windowsOpen, at: 2, delay: 2), "reopening cancels pending quit")
        expect(!reopened.observe(.noWindows, at: 3, delay: 2), "reclosing requires a fresh delay")
        expect(!reopened.observe(.noWindows, at: 4, delay: 2), "old empty interval must not carry over")
        expect(reopened.observe(.noWindows, at: 5, delay: 2), "fresh uninterrupted interval can quit")

        var failedRead = QuitPolicy()
        _ = failedRead.observe(.windowsOpen, at: 0, delay: 2)
        _ = failedRead.observe(.noWindows, at: 1, delay: 2)
        expect(!failedRead.observe(.unknown, at: 2, delay: 2), "AX read failure must not mean no windows")
        expect(!failedRead.observe(.noWindows, at: 3, delay: 2), "AX recovery restarts full delay")
        expect(!failedRead.observe(.noWindows, at: 4, delay: 2), "AX failure cancels previous elapsed time")
        expect(failedRead.observe(.noWindows, at: 5, delay: 2), "recovered samples can eventually quit")

        var paused = QuitPolicy()
        _ = paused.observe(.windowsOpen, at: 0, delay: 2)
        _ = paused.observe(.noWindows, at: 1, delay: 2)
        expect(!paused.observe(.noWindows, at: 30, delay: 2, suspended: true), "pause blocks an overdue quit")
        expect(!paused.observe(.noWindows, at: 31, delay: 2), "resume restarts full delay")
        expect(!paused.observe(.noWindows, at: 32, delay: 2), "paused time cannot count toward delay")
        expect(paused.observe(.noWindows, at: 33, delay: 2), "resume permits a fresh continuous interval")

        var spaceChanged = QuitPolicy()
        _ = spaceChanged.observe(.windowsOpen, at: 0, delay: 2)
        _ = spaceChanged.observe(.noWindows, at: 1, delay: 2)
        spaceChanged.cancelPending()
        expect(!spaceChanged.observe(.noWindows, at: 10, delay: 2), "Space change cancels prior interval")
        expect(!spaceChanged.observe(.noWindows, at: 11, delay: 2), "Space stabilization requires full delay")
        expect(spaceChanged.observe(.noWindows, at: 12, delay: 2), "later verified closure may quit")

        var unsent = QuitPolicy()
        _ = unsent.observe(.windowsOpen, at: 0, delay: 2)
        _ = unsent.observe(.noWindows, at: 1, delay: 2)
        expect(unsent.observe(.noWindows, at: 3, delay: 2), "candidate becomes ready")
        // A final safety check vetoed this candidate before terminate() was
        // called. Unlike a sent request, it may be retried after a new interval.
        unsent.restoreUnsentCandidate()
        expect(!unsent.observe(.noWindows, at: 4, delay: 2), "unsent candidate restoration starts fresh delay")
        expect(!unsent.observe(.noWindows, at: 5, delay: 2), "restoration cannot immediately retry")
        expect(unsent.observe(.noWindows, at: 6, delay: 2), "restored unsent candidate may retry once ready")
        expect(!unsent.observe(.noWindows, at: 60, delay: 2), "sent retry is consumed exactly once")

        for configuredDelay in [0.0, -100.0, 0.1] {
            var minimum = QuitPolicy()
            _ = minimum.observe(.windowsOpen, at: 10, delay: configuredDelay)
            _ = minimum.observe(.noWindows, at: 11, delay: configuredDelay)
            expect(!minimum.observe(.noWindows, at: 11.499, delay: configuredDelay), "minimum delay must be 0.5 seconds")
            expect(minimum.observe(.noWindows, at: 11.5, delay: configuredDelay), "minimum delay allows quit at 0.5 seconds")
        }

        print("Policy regressions passed (\(checks) checks)")
    }
}
