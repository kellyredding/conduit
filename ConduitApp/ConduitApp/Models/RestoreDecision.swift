import Foundation

/// What a satisfied path event should do about an armed restore.
///
/// The decision lives here rather than inside the store because it is the part
/// that keeps being wrong and the only part a check can reach: everything
/// around it is a workspace notification, a path monitor and a subprocess,
/// none of which the smoke target can stand up. Foundation only, so it can.
///
/// Carrying the surviving `wanted` set out with the action is what makes the
/// whole thing one pure step. The alternative — subtract in the store, then
/// ask here what to do — puts half the rule back where it cannot be checked.
struct RestoreDecision: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        /// Run an attempt against what remains wanted.
        case act
        /// Give up. Nothing further fires until the next wake.
        case disarm(Reason)
        /// Stay armed and do nothing this time.
        case hold(Reason)
    }

    /// Named for the rule that fired, so one log line says which it was. A
    /// restore that silently does nothing otherwise costs a whole sleep cycle
    /// to diagnose, because from outside the process an arming that declined
    /// and one that never happened look identical.
    enum Reason: String, Equatable, Sendable {
        /// Every wanted profile has been observed connected.
        case confirmed
        /// Armed at a wake that never produced a usable network.
        case expired
        /// The attempt cap is spent.
        case exhausted
        /// An attempt is still moving, and interrupting it would destroy the
        /// work it has already done.
        case settling
    }

    let action: Action

    /// What is still wanted. The caller assigns this back before acting, so a
    /// confirmation seen here is not seen again by the next event.
    let wanted: Set<String>
}

extension RestoreDecision {
    /// Assumes the restore is armed with no attempt in flight — both are facts
    /// the store owns outright and can test for nothing.
    ///
    /// The order of the four rules is load-bearing, and each position was paid
    /// for:
    ///
    /// 1. **Subtract what is connected, but only once an attempt has run.** A
    ///    reading taken before the first attempt describes the network the
    ///    machine had before it slept; taken 52 ms after arming it confirmed a
    ///    restore that had not happened and stood the whole thing down.
    ///    Afterwards the reading is trustworthy structurally, because the
    ///    disconnect that begins every attempt destroys any stale `Connected`.
    ///
    /// 2. **Expiry before settling.** An arming whose wake never produced a
    ///    satisfied path event is stale, and the events that eventually arrive
    ///    are the ones a person's own connect generates. Holding it because
    ///    that connect is moving would keep it armed for the event after.
    ///
    /// 3. **Settling before the cap**, so a live attempt is never charged for
    ///    an attempt it did not spend.
    ///
    /// Subtracting first is also what closes the window this was written for:
    /// `ProfileState.isSettling` is false for a profile that has arrived, so
    /// between arrival and the next poll the arming used to be live and
    /// unguarded — and arriving is itself what raises the path event that lands
    /// there.
    static func evaluate(
        attempts: Int,
        maxAttempts: Int,
        armedAt: Date?,
        armWindow: TimeInterval,
        wanted: Set<String>,
        profiles: [ProfileState],
        settleWindow: TimeInterval,
        now: Date = Date()
    ) -> RestoreDecision {
        var remaining = wanted

        if attempts > 0 {
            remaining.subtract(profiles.filter(\.isConnected).map(\.name))
            if remaining.isEmpty {
                return RestoreDecision(
                    action: .disarm(.confirmed), wanted: remaining
                )
            }
        }

        if attempts == 0, let armedAt,
            now.timeIntervalSince(armedAt) > armWindow
        {
            return RestoreDecision(action: .disarm(.expired), wanted: remaining)
        }

        let stillMoving = remaining.contains { name in
            profiles.first { $0.name == name }?
                .isSettling(within: settleWindow, now: now) ?? false
        }
        if stillMoving {
            return RestoreDecision(action: .hold(.settling), wanted: remaining)
        }

        if attempts >= maxAttempts {
            return RestoreDecision(
                action: .disarm(.exhausted), wanted: remaining
            )
        }

        return RestoreDecision(action: .act, wanted: remaining)
    }
}
