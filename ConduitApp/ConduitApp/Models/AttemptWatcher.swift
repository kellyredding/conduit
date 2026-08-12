import Foundation

/// Polls a profile to a terminal outcome after a connect or disconnect.
///
/// MIRROR (behavioral, not literal):
///   tools/conduit-vpn/src/conduit_vpn/attempt_watcher.cr
///
/// Two properties of the client make this less obvious than it looks.
///
/// First, `connect` returns immediately with exit 0. That reports the attempt
/// *started*. Trusting it announces success on connections that never happen.
///
/// Second, `NotConnected` is ambiguous: it is both "idle" and "the attempt you
/// just made failed", and nothing in the response separates them. They are
/// told apart by watching for progress — once any transitional state has been
/// seen, a return to `NotConnected` is a failure. Before that it means the
/// client has not registered the attempt yet, which it needs a moment to do,
/// so a small number of consecutive readings are tolerated first.
///
/// That tolerance is counted in polls rather than measured in seconds
/// deliberately. A slow machine changes how long a poll takes but not how many
/// readings it takes for the client to catch up, and a count behaves
/// identically under a test clock and a real one.
enum AttemptOutcome: Equatable, Sendable {
    case connected
    case failed
    case disconnected
    case timedOut

    /// Stopped watching because the person asked. Absent from the command-line
    /// original, which has nobody to ask it: there, a watch runs until it
    /// resolves. Kept distinct from every other case because it is the one
    /// outcome that says nothing at all about the connection.
    case cancelled

    /// A timeout is not a failure. With sign-in happening in a browser, giving
    /// up watching says nothing about whether the attempt will succeed, and
    /// anything that conflates the two will report a loss on something still
    /// in progress.
    var isFailure: Bool { self == .failed }
}

enum AttemptEvent: Equatable, Sendable {
    /// The status changed. Fires once per distinct reading rather than once
    /// per poll, so narration does not repeat itself while nothing happens.
    case observed(VPNStatus?)

    /// Long enough in the sign-in state to be worth explaining. Nothing
    /// separates "the browser opened" from "someone is typing" from "they
    /// walked away", so the only honest move is to say a browser is waiting
    /// and keep watching.
    case identityHint
}

/// Injected so checks drive time instead of spending it.
protocol AttemptClock: Sendable {
    /// Monotonic seconds from an arbitrary origin. Monotonic rather than
    /// wall-clock: this measures an elapsed span across a window in which the
    /// machine may sleep, and a clock that can step backwards would make a
    /// timeout unreachable.
    func now() -> TimeInterval
    func sleep(_ seconds: TimeInterval) async
}

struct SystemAttemptClock: AttemptClock {
    func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    func sleep(_ seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        try? await Task.sleep(for: .seconds(seconds))
    }
}

struct AttemptWatcher: Sendable {
    typealias Probe = @Sendable () async -> VPNStatus?

    private let probe: Probe
    private let clock: AttemptClock

    init(probe: @escaping Probe, clock: AttemptClock = SystemAttemptClock()) {
        self.probe = probe
        self.clock = clock
    }

    func watchConnect(
        timeout: TimeInterval,
        hintAfter: TimeInterval,
        interval: TimeInterval,
        gracePolls: Int,
        onEvent: @Sendable (AttemptEvent) async -> Void
    ) async -> AttemptOutcome {
        let started = clock.now()
        var progressed = false
        var idleReadings = 0
        var hinted = false
        var previous: VPNStatus?
        var first = true

        while true {
            if Task.isCancelled { return .cancelled }

            let status = await probe()
            let elapsed = clock.now() - started

            if first || previous != status {
                await onEvent(.observed(status))
                previous = status
                first = false
            }

            switch status {
            case .none:
                // A status this build does not recognize. Treated as motion
                // rather than as failure: a client that added a state did not
                // thereby break the connection.
                progressed = true
                idleReadings = 0

            case .connected:
                return .connected

            case .notConnected:
                if progressed { return .failed }
                idleReadings += 1
                if idleReadings >= gracePolls { return .failed }

            default:
                progressed = true
                idleReadings = 0
                if status == .waitingForIdentity, !hinted, elapsed >= hintAfter {
                    await onEvent(.identityHint)
                    hinted = true
                }
            }

            if elapsed >= timeout { return .timedOut }
            await clock.sleep(interval)
        }
    }

    func watchDisconnect(
        timeout: TimeInterval,
        interval: TimeInterval,
        onEvent: @Sendable (AttemptEvent) async -> Void
    ) async -> AttemptOutcome {
        let started = clock.now()
        var previous: VPNStatus?
        var first = true

        while true {
            if Task.isCancelled { return .cancelled }

            let status = await probe()
            let elapsed = clock.now() - started

            if first || previous != status {
                await onEvent(.observed(status))
                previous = status
                first = false
            }

            if status == .notConnected { return .disconnected }
            if elapsed >= timeout { return .timedOut }
            await clock.sleep(interval)
        }
    }
}
