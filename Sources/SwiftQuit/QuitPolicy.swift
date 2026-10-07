import Foundation

/// A complete, uninterrupted zero-window interval after a positive observation.
/// Errors never count as zero; a cancelled quit request is never retried until
/// a window is observed again. Time is monotonic, independent of clock changes.
struct QuitPolicy {
    enum Observation: Equatable { case windowsOpen, noWindows, unknown }
    private(set) var armed = false
    private(set) var zeroSince: TimeInterval?

    mutating func observe(_ observation: Observation, at now: TimeInterval,
                          delay: TimeInterval, suspended: Bool = false) -> Bool {
        if suspended {
            zeroSince = nil
            return false
        }
        switch observation {
        case .unknown:
            zeroSince = nil
        case .windowsOpen:
            armed = true
            zeroSince = nil
        case .noWindows:
            guard armed else { return false }
            guard let start = zeroSince else {
                zeroSince = now
                return false
            }
            guard now - start >= max(0.5, delay) else { return false }
            armed = false
            zeroSince = nil
            return true
        }
        return false
    }

    mutating func cancelPending() { zeroSince = nil }
    /// Only for a candidate cancelled BEFORE sending an actual quit request.
    mutating func restoreUnsentCandidate() { armed = true; zeroSince = nil }
}

/// WindowServer visibility is a safety veto, never evidence that a trackable
/// window exists. In particular, it cannot arm a later zero-window transition:
/// the same window may disappear from the on-screen list after a Space change.
enum WindowEvidence {
    static func observation(hasLiveAXWindow: Bool, onScreen: Bool?,
                            uncertain: Bool) -> QuitPolicy.Observation {
        guard !uncertain, let onScreen else { return .unknown }
        if hasLiveAXWindow { return .windowsOpen }
        return onScreen ? .unknown : .noWindows
    }
}

/// A red-click intent remains usable during the closing animation, then expires
/// as soon as a confirmed closure is followed by a live window. This prevents a
/// subsequent Cmd-H from reusing an old click after the window has reopened.
struct CloseIntentLifecycle {
    private(set) var sawClosure = false

    /// Returns true when the caller must discard the intent.
    mutating func observe(_ observation: QuitPolicy.Observation) -> Bool {
        switch observation {
        case .noWindows:
            sawClosure = true
        case .windowsOpen:
            return sawClosure
        case .unknown:
            break
        }
        return false
    }
}
