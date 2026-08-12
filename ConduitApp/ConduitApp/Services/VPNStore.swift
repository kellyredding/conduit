import AppKit
import Foundation
import Network
import os

/// What the menu bar knows, kept current by polling.
///
/// The governing idea is reconciliation, not ownership. Conduit is never the
/// only actor: connections are made and torn down from terminals and by other
/// tools, and one is often already live when this launches. So the store
/// renders whatever the client reports and never assumes a state because it
/// asked for one.
///
/// It acts in exactly one circumstance: restoring, after a wake, connections
/// that were live before the machine slept. Everything else here still only
/// reads. Reconciliation survives the change — a restore is issued and then
/// forgotten, and what the menu shows afterwards comes from the client like
/// everything else, never from the fact that a connect was requested.
@MainActor
final class VPNStore: ObservableObject {
    static let shared = VPNStore()

    @Published private(set) var profiles: [ProfileState] = []
    @Published private(set) var health: ClientHealth = .unknown
    @Published private(set) var lastUpdated: Date?

    /// Only populated while a surface that displays them is open — the panel or
    /// the detail window. Nobody can see a byte count in a closed menu, and
    /// fetching it costs one subprocess per live tunnel.
    @Published private(set) var counters: [String: VPNByteCounters] = [:]

    /// Rates, differenced from those counters, per connected profile.
    ///
    /// Discarded when the last surface showing them closes, rather than kept for
    /// the next opening. A plot of rates is read as "now", and history from a
    /// window that was closed an hour ago says so only in an axis label nobody
    /// reads. Sampling that runs while somebody is watching should produce
    /// history that describes exactly that period.
    @Published private(set) var throughput: [String: ThroughputSeries] = [:]

    /// Transitions as they were observed, whether or not they were announced.
    @Published private(set) var activity = ActivityLog()

    /// Routes and resolvers, read from the OS on events rather than polled.
    @Published private(set) var facts = TunnelFacts()

    var iconState: MenuIconState {
        MenuIcon.state(for: profiles, health: health, settling: isSettling)
    }

    /// Something is changing: Conduit's own action, a restore not yet confirmed,
    /// or any transition still moving — whoever started it.
    ///
    /// The middle case exists because a restore is not over when `connect`
    /// returns. The client accepts an attempt and exits 0 several seconds
    /// before a tunnel exists, which left the bar hollow for nine seconds in
    /// the middle of an attempt Conduit was itself driving.
    var isSettling: Bool {
        if !activeAttempts.isEmpty { return true }
        if restorePending, restoreAttempts > 0 { return true }
        let configured = ConduitConfig.seconds("connect-timeout")
        return profiles.contains {
            $0.isSettling(within: configured > 0 ? configured : 120)
        }
    }

    private let client: VPNClient
    private let probe = SystemProbe()
    private var pollTask: Task<Void, Never>?
    private var menuIsOpen = false
    private var detailIsOpen = false

    /// Whether anyone can see a per-connection detail. Both surfaces show
    /// throughput, so both want sampling — and asking this rather than asking
    /// about the menu is what stops closing the panel from stopping the samples
    /// underneath an open detail window.
    private var isWatching: Bool { menuIsOpen || detailIsOpen }
    private var pathMonitor: NWPathMonitor?
    private var observers: [NSObjectProtocol] = []

    /// The profile listing, cached. Which profiles exist changes only when one
    /// is imported or removed — never by this application, and rarely at all —
    /// while which are connected changes constantly. Re-reading both at the
    /// idle rate would double the subprocess count for an answer that is
    /// almost always identical to the last one.
    private var knownProfiles: [VPNProfile] = []
    private var profilesReadAt: Date?

    /// Deliberately far longer than any polling interval. At sixty seconds it
    /// matched the idle interval exactly, so the entry expired on every cycle
    /// and the cache did nothing but double the call rate — measured as one
    /// profile listing for every connection listing while nominally idle.
    ///
    /// Staleness is bounded by events rather than by this number: the list is
    /// re-read when the menu opens, after any failure, and whenever a
    /// connection names a profile it does not contain. Those are the moments
    /// being wrong would show. Between them, a profile appearing or vanishing
    /// is something only the person who imported it knows about, and they can
    /// open the menu.
    private let profileMaxAge: TimeInterval = 30 * 60

    /// When an event last caused a look, so a burst of them causes one.
    private var lastEventRefresh = Date.distantPast
    private let eventRefreshMinimumGap: TimeInterval = 3

    // MARK: - Restore on wake
    //
    // Sleep kills every tunnel, and the client notices about six seconds after
    // the machine wakes — reliably before the network is back. Its attempt
    // fails there, and then holds the profile against replacement for roughly
    // ten minutes, answering "Already connected to profile" the entire time
    // while no route, no interface address and no bytes exist. Measured twice.
    //
    // So the difference between this and what the client already does is one
    // step: waiting for a usable network before asking. That wait is an event
    // rather than a delay, which is what keeps a threshold out of it.

    /// Restore decisions only, one line per event rather than per poll.
    ///
    /// A wake happens once and cannot be replayed, so a restore that silently
    /// does nothing costs an entire sleep cycle to diagnose — from outside the
    /// process, one that never armed and one that armed and declined look
    /// identical. Three separate defects were each found in a single cycle
    /// because these lines named the step that stopped, which is the whole
    /// reason they survive rather than being scaffolding that got deleted.
    ///
    /// This is the unified log, which macOS bounds and rotates itself. It is
    /// not the vendor's log directory, which grows a file per day and is
    /// pruned by ClientLogs, so nothing here contributes to that.
    ///
    /// Profile names are deliberately absent: this is a public repository and
    /// the unified log is readable by anything on the machine. Counts carry
    /// the whole diagnostic value.
    nonisolated static let log = Logger(
        subsystem: "com.kellyredding.Conduit", category: "restore"
    )

    /// The last observation of what was connected, kept current by polling.
    /// The sleep notification is the precise signal and this is the durable
    /// one: it survives a notification that never arrives, which is not
    /// hypothetical — nothing guarantees `willSleep` is delivered before power
    /// is cut, and the restore should not depend on a courtesy.
    private var lastConnected: Set<String> = []

    /// Names that were connected when the lid closed. Held only in memory, on
    /// purpose: a relaunched Conduit has no business restoring a connection it
    /// never saw. Read-only operation means a tunnel outlives the app, and a
    /// fresh launch reconciles that tunnel into view without having asked for
    /// it — the same reasoning says it must not resurrect one either.
    private var connectedBeforeSleep: Set<String> = []

    /// Set at wake, cleared when every wanted profile is confirmed connected or
    /// the attempts run out.
    private var restorePending = false

    /// Wanted but not yet confirmed. Names leave this set only when a poll has
    /// actually observed them connected — never because a connect was accepted,
    /// which says an attempt started and nothing more.
    private var restoreWanted: Set<String> = []

    /// One attempt is not enough, because there is no reliable signal for "the
    /// network is usable again". A satisfied path means a route exists, and
    /// measured, the first one arrives 68 ms after waking — describing the
    /// network the machine had before it slept. So each subsequent path event
    /// gets another try, which converges without a timer: path events stop once
    /// the network settles. The cap exists only so a flapping interface cannot
    /// drive this indefinitely, since every attempt is a browser round-trip.
    private var restoreAttempts = 0
    private let restoreMaxAttempts = 4

    /// Attempts take about nine seconds and path events arrive faster than
    /// that, so without this a settling network starts several at once.
    private var restoreInFlight = false

    /// Profiles Conduit is itself acting on. This is the only in-flight signal
    /// worth having: it is a fact the store owns rather than an inference about
    /// whether somebody else's transition is still alive.
    @Published private(set) var activeAttempts: Set<String> = []

    init(client: VPNClient? = nil) {
        self.client = client ?? VPNClient.fromConfiguration()
    }

    // MARK: - Lifecycle

    func start() {
        guard pollTask == nil else { return }
        // Also the positive control for this log: if a wake produces no restore
        // line, this one still being present proves the code did not run rather
        // than that the logging did not.
        Self.log.notice("store started")
        observeSleep()
        observeWake()
        observeNetwork()
        restartPolling()
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }

    // MARK: - Cadence
    //
    // Two rates, keyed to whether anyone can see the answer. The menu is closed
    // almost always, and at rest a single call covers every profile: absence
    // from the connection listing is itself the answer for the rest.

    // Keyed on the same question the bar asks: is anything actually moving.
    //
    // Both previous rules were wrong in opposite directions. Keying on any
    // transitional state watched an abandoned attempt at the active rate for
    // the ten minutes it took to expire. Keying on Conduit's own attempts left
    // a connection started from a terminal — which is most of them — invisible
    // for a full idle interval, measured at 51 seconds with a tunnel already
    // carrying traffic.
    //
    // Asking whether the transition is still moving gets both: a live one is
    // watched closely whoever started it, and an abandoned one drops back to
    // resting without waiting out the client's timeout.
    private var interval: TimeInterval {
        let name = isWatching || isSettling
            ? "poll-interval-active"
            : "poll-interval-idle"
        let seconds = ConduitConfig.seconds(name)
        return seconds > 0 ? seconds : 5
    }

    /// How long a gap can be and still be differenced into a rate. Five missed
    /// samples, derived from the cadence rather than picked: a fixed number of
    /// seconds would silently discard every sample on a machine configured to
    /// poll more slowly than it, leaving a throughput readout permanently empty
    /// for no visible reason.
    private static var staleAfter: TimeInterval {
        let active = ConduitConfig.seconds("poll-interval-active")
        return max((active > 0 ? active : 2) * 5, 10)
    }

    func menuOpened() {
        menuIsOpen = true
        // Opening the menu is the one moment a stale profile list would be
        // seen, so it is the one moment worth paying for a fresh one.
        profilesReadAt = nil
        // Restarting refreshes immediately rather than waiting out a sleep that
        // may have twenty seconds left on it — opening the menu is exactly when
        // a stale answer is most visible.
        restartPolling()
    }

    func menuClosed() {
        menuIsOpen = false
        stopWatchingIfUnobserved()
        restartPolling()
    }

    /// Called by the window controller rather than by the view's lifecycle.
    ///
    /// A window ordered out does not reliably retire the SwiftUI view inside it,
    /// so `onDisappear` is not a signal that sampling should stop — and a
    /// sampler that never stops is the exact cost this was scoped to avoid.
    func detailOpened() {
        detailIsOpen = true
        restartPolling()
        refreshFactsNow()
    }

    func detailClosed() {
        detailIsOpen = false
        stopWatchingIfUnobserved()
        restartPolling()
    }

    /// Only once *both* surfaces are closed. Cancelling in-flight queries when
    /// the panel closes over an open detail window would abort that window's own
    /// samples, and clearing the counters would blank the readout it is showing.
    private func stopWatchingIfUnobserved() {
        guard !isWatching else { return }
        counters.removeAll()
        throughput.removeAll()
        Task { await client.cancelAll() }
    }

    func refreshNow() {
        restartPolling()
    }

    private func restartPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.loop()
        }
    }

    private func loop() async {
        while !Task.isCancelled {
            await refresh()
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .seconds(interval))
        }
    }

    // MARK: - Refresh

    private var profilesAreStale: Bool {
        guard let readAt = profilesReadAt, !knownProfiles.isEmpty else { return true }
        return Date().timeIntervalSince(readAt) > profileMaxAge
    }

    private func refresh() async {
        do {
            if profilesAreStale {
                knownProfiles = try await client.listProfiles()
                profilesReadAt = Date()
            }

            var listedConnections = try await client.listConnections()

            // A connection naming a profile the cache has never heard of means
            // the cache is behind, and the cost of being wrong is a live tunnel
            // that is invisible in the menu. Re-read once and reconcile against
            // the truth rather than showing a partial answer for up to a minute.
            if !ProfileReconciler.orphanedConnections(
                profiles: knownProfiles, connections: listedConnections
            ).isEmpty {
                knownProfiles = try await client.listProfiles()
                profilesReadAt = Date()
                listedConnections = try await client.listConnections()
            }

            profiles = ProfileReconciler.states(
                profiles: knownProfiles,
                connections: listedConnections
            )

            let now = Date()
            // Read before the assignment below overwrites it. Only a recovery
            // from an actual failure is worth an entry: the initial `.unknown`
            // is not a failure, so a launch does not open the log with news
            // about a client that was never unreachable.
            if health.isUnavailable {
                activity.record(.clientReady, at: now)
            }
            health = .ready
            lastUpdated = now

            let nowConnected = Set(profiles.filter(\.isConnected).map(\.name))
            let appeared = nowConnected.subtracting(lastConnected)
            let vanished = lastConnected.subtracting(nowConnected)
            if hasObserved {
                // Recorded before announcing, and unconditionally. The
                // announcement is suppressed for a change the person made
                // themselves — they watched it happen — but the log is a record
                // rather than news, and one with holes exactly where somebody
                // acted is a record that cannot be read.
                for name in appeared.sorted() {
                    activity.record(.connected, profile: name, at: now)
                }
                for name in vanished.sorted() {
                    activity.record(.disconnected, profile: name, at: now)
                }
                announce(appeared: appeared, vanished: vanished)
            } else {
                // The first successful reading. Anything connected here was
                // established before this process existed, so it is a state
                // found rather than a transition seen — recorded to establish
                // the baseline, and deliberately not announced, since a tunnel
                // that has been up for hours is not news.
                for name in nowConnected.sorted() {
                    activity.record(.alreadyConnected, profile: name, at: now)
                }
            }
            hasObserved = true
            lastConnected = nowConnected

            // A series belongs to a live tunnel. Left in place, one for a
            // profile that disconnected would go on showing the rates it had
            // when it died, and the next connection would difference against
            // counters from the previous tunnel.
            throughput = throughput.filter { nowConnected.contains($0.key) }

            // Routes and resolvers change when a tunnel appears or goes away,
            // which is precisely this condition — so they are re-read here
            // rather than on a timer.
            if !appeared.isEmpty || !vanished.isEmpty {
                refreshFactsNow()
            }

            // A restore is finished when a poll has actually seen the tunnel,
            // not when a connect was accepted — the client accepts an attempt
            // and exits 0 long before there is anything to show for it.
            //
            // Only after an attempt has run *and finished*. This is the third
            // place the same mistake appeared: any reading taken between the
            // wake and the first disconnect describes the network the machine
            // had before it slept, and code that consults it concludes the
            // tunnel is fine. Here it logged "confirmed after 0 attempts" 52 ms
            // after arming and stood the whole restore down. Requiring a
            // completed attempt makes the reading trustworthy structurally: the
            // disconnect that starts every attempt destroys any stale
            // Connected, so anything seen afterwards is genuinely current.
            if restorePending, restoreAttempts > 0, !restoreInFlight {
                restoreWanted.subtract(lastConnected)
                if restoreWanted.isEmpty {
                    restorePending = false
                    Self.log.notice(
                        "restore confirmed after \(self.restoreAttempts, privacy: .public) attempt(s)"
                    )
                }
            }

            if isWatching {
                await refreshCounters()
            }
        } catch is CancellationError {
            return
        } catch {
            // Only the transition into unavailability, not every failed poll —
            // a client that stays down is polled every few seconds and would
            // otherwise fill the log with one entry per attempt and push out
            // the transitions worth keeping.
            if !health.isUnavailable {
                activity.record(.clientUnavailable, at: Date())
            }
            // The last known profile states are deliberately left in place. A
            // client that stopped answering has not told us the tunnels went
            // away, and blanking the menu would assert something untrue while
            // the banner already says the real thing.
            health = .unavailable(
                (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            )
            // Force a re-read once the client answers again: whatever went
            // wrong may well have been a profile being added or removed.
            profilesReadAt = nil
        }
    }

    /// Says what changed, for the changes nobody was in a position to see.
    ///
    /// Worded as observation and never as cause. Conduit cannot know why a
    /// connection ended, and a tunnel torn down deliberately from a terminal
    /// is indistinguishable from one that collapsed — measured twice, the
    /// state that would have carried the difference does not survive a poll.
    private func announce(appeared: Set<String>, vanished: Set<String>) {
        for name in appeared.sorted() {
            guard panelInitiated.remove(name) == nil else { continue }
            Notifier.post(title: "\(name) connected")
        }
        for name in vanished.sorted() {
            guard panelInitiated.remove(name) == nil else { continue }
            Notifier.post(title: "\(name) disconnected")
        }
    }

    private func refreshCounters() async {
        let staleAfter = Self.staleAfter
        for profile in profiles where profile.isConnected {
            guard !Task.isCancelled else { return }
            let status = try? await client.status(
                profile: profile.name,
                details: true
            )
            let details = status?.attempt?.details
            if let details {
                counters[profile.name] = details
            }

            // Recorded even when absent, which is why the optional travels this
            // far intact instead of being flattened to zero at the decoder. A
            // missing payload is a hole in the record; a series not told about
            // it differences straight across the hole and reports two intervals
            // of traffic as the rate of one.
            var series = throughput[profile.name] ?? ThroughputSeries()
            series.record(details, at: Date(), staleAfter: staleAfter)
            throughput[profile.name] = series
        }
    }

    /// Reads routes and resolvers, if anyone is looking at them.
    ///
    /// Guarded on the detail window being open rather than reading
    /// unconditionally: nothing else displays these, so two subprocesses per
    /// connection change would be spent on an answer with no reader.
    func refreshFactsNow() {
        guard detailIsOpen else { return }
        Task { [weak self] in
            guard let read = await self?.probe.read() else { return }
            self?.facts = read
        }
    }

    // MARK: - Actions

    /// Changes the person is already watching, so the announcement is skipped.
    ///
    /// Only the panel populates this. A restore deliberately does not: the
    /// whole premise of restoring is that nobody was there. Entries are
    /// consumed by the transition they predicted, and cleared on an attempt
    /// that ended without one, so a connect that failed cannot leave a mark
    /// that silences the next connection somebody else makes.
    private var panelInitiated: Set<String> = []

    /// Whether a first successful reading has been taken.
    ///
    /// Without it, launching would announce every tunnel already up as though
    /// it had just happened — and one usually is, because the app can be
    /// restarted underneath a live connection and reconciles it into view.
    private var hasObserved = false

    /// What an attempt has to say for itself beyond its status: the browser
    /// hint while it waits, or why it ended if it ended badly. Keyed by
    /// profile because several can be in flight at once.
    @Published private(set) var notes: [String: String] = [:]

    /// Which profiles have a cancellable attempt running.
    ///
    /// Published, and deliberately not derived from the task table: a view
    /// asking the table directly would read the right answer and never be told
    /// to look again, since a dictionary of tasks publishes nothing. It worked
    /// only because a published set happened to change at the same instant,
    /// and the restore path already breaks that correspondence — it marks a
    /// profile active without owning a task to cancel.
    @Published private(set) var attemptsInProgress: Set<String> = []

    private var attemptTasks: [String: Task<Void, Never>] = [:]

    func isActing(on profile: String) -> Bool {
        attemptsInProgress.contains(profile)
    }

    /// Refused for a profile the rule marks unless the caller says it has
    /// asked. The gate lives here rather than only in the panel so that a
    /// second caller cannot reach a sensitive endpoint by not knowing about it
    /// — the same reason the command line refuses without a confirming flag.
    func connect(profile name: String, confirmed: Bool) {
        guard attemptTasks[name] == nil else { return }
        guard confirmed || !Sensitivity.isSensitive(name) else {
            notes[name] = "Needs confirmation"
            return
        }

        notes[name] = nil
        activeAttempts.insert(name)
        attemptsInProgress.insert(name)
        // The target, and whatever the release below takes down on the way.
        // Both are changes this person is making with the panel open in front
        // of them, so neither is news.
        panelInitiated.insert(name)
        panelInitiated.formUnion(lastConnected)
        attemptTasks[name] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishAttempt(name) }

            // One tunnel at a time. Asking for a second while one is live
            // fails, and being told to go and disconnect the first by hand is
            // a step with no decision in it.
            await self.client.releaseOthers(except: name)

            do {
                try await self.client.connect(profile: name)
            } catch {
                // The client refuses outright when the profile is already held
                // by an attempt of its own, which is a sentence rather than a
                // state and is worth showing verbatim.
                self.notes[name] = Self.describe(error)
                return
            }

            let outcome = await self.watcher(for: name).watchConnect(
                timeout: Self.number("connect-timeout", 120),
                hintAfter: Self.number("identity-hint-after", 15),
                interval: Self.number("poll-interval-active", 2),
                gracePolls: ConduitConfig.int("connect-grace-polls") ?? 3,
                onEvent: self.forward(to: name)
            )

            switch outcome {
            case .connected, .disconnected:
                self.notes[name] = nil
            case .failed:
                self.notes[name] = "Could not connect"
                self.panelInitiated.remove(name)
                Notifier.post(title: "\(name) could not connect")
            case .timedOut:
                // Not a failure. Sign-in happens in a browser, so giving up
                // watching says nothing about whether it will still land, and
                // wording it as a loss would be a guess.
                self.notes[name] = "Still trying — stopped watching"
                self.panelInitiated.remove(name)
                Notifier.post(
                    title: "\(name) is taking longer than expected",
                    body: "Sign-in may still be waiting in your browser."
                )
            case .cancelled:
                self.panelInitiated.remove(name)
                await self.release(name)
            }
        }
    }

    func disconnect(profile name: String) {
        guard attemptTasks[name] == nil else { return }

        notes[name] = nil
        activeAttempts.insert(name)
        attemptsInProgress.insert(name)
        panelInitiated.insert(name)
        attemptTasks[name] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishAttempt(name) }

            do {
                try await self.client.disconnect(profile: name)
            } catch {
                self.notes[name] = Self.describe(error)
                return
            }

            let outcome = await self.watcher(for: name).watchDisconnect(
                timeout: Self.number("connect-timeout", 120),
                interval: Self.number("poll-interval-active", 2),
                onEvent: self.forward(to: name)
            )
            if outcome == .timedOut {
                self.notes[name] = "Still tearing down"
                self.panelInitiated.remove(name)
            }
        }
    }

    /// Stopping the watch is not stopping the attempt: the client carries on,
    /// and a profile left mid-attempt holds itself against any replacement for
    /// about ten minutes while reporting that it is already connected. So a
    /// cancel that only stopped watching would leave the profile unusable and
    /// look like it had been dealt with. The release is the cancel.
    func cancelAttempt(profile name: String) {
        attemptTasks[name]?.cancel()
    }

    private func release(_ name: String) async {
        try? await client.disconnect(profile: name)
        notes[name] = nil
    }

    private func finishAttempt(_ name: String) {
        activeAttempts.remove(name)
        attemptsInProgress.remove(name)
        attemptTasks[name] = nil
        refreshNow()
    }

    /// The watcher runs outside this actor, so its events are hopped back
    /// rather than assumed to arrive here.
    private func forward(to name: String) -> @Sendable (AttemptEvent) async -> Void {
        { [weak self] event in
            guard case .identityHint = event else { return }
            await MainActor.run {
                self?.notes[name] = "Waiting for browser sign-in"
            }
        }
    }

    private func watcher(for name: String) -> AttemptWatcher {
        let client = self.client
        return AttemptWatcher(probe: {
            try? await client.status(profile: name).status
        })
    }

    private static func number(_ key: String, _ fallback: TimeInterval) -> TimeInterval {
        let configured = ConduitConfig.seconds(key)
        return configured > 0 ? configured : fallback
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: - Triggers

    /// The last moment the pre-sleep truth is still observable. Taken from the
    /// most recent poll rather than by asking the client, because the machine
    /// is on its way down and a subprocess may not return before it stops.
    ///
    /// Captured **synchronously**. This first hopped to the MainActor through a
    /// `Task`, which is correct-looking and does not work: the notification
    /// arrives with a moment left before the machine suspends, and the next
    /// scheduling point never came. Measured — the wake half of the same
    /// pattern ran fine and produced a poll 0.55 s after waking, while this one
    /// never ran at all, so the restore had nothing to restore and every later
    /// trigger correctly declined to act.
    private func observeSleep() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(
            center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.connectedBeforeSleep = Set(
                        self.profiles.filter(\.isConnected).map(\.name)
                    )
                    Self.log.notice(
                        "sleep: remembered \(self.connectedBeforeSleep.count, privacy: .public) connected"
                    )
                }
            }
        )
    }

    private func observeWake() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(
            center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }

                    // Read the memory before anything refreshes over it. The
                    // sleep notification is the precise source; the polled one
                    // is the source that is always there.
                    let remembered = self.connectedBeforeSleep.isEmpty
                        ? self.lastConnected
                        : self.connectedBeforeSleep
                    self.connectedBeforeSleep = []
                    self.restoreWanted = remembered
                    self.restoreAttempts = 0

                    // Arm the restore. It deliberately does not run here —
                    // firing at wake is precisely the client's mistake.
                    let enabled = ConduitConfig.bool("restore-on-wake")
                    self.restorePending = enabled && !remembered.isEmpty
                    Self.log.notice(
                        """
                        wake: enabled=\(enabled, privacy: .public) \
                        remembered=\(remembered.count, privacy: .public) \
                        armed=\(self.restorePending, privacy: .public)
                        """
                    )

                    // Status right after a wake is the least trustworthy
                    // reading there is: measured, the client went on claiming
                    // Connected for six seconds with the network gone the whole
                    // time. So this look is for the menu, and nothing decides
                    // anything on what it returns.
                    self.refreshNow()
                }
            }
        )
    }

    private func observeNetwork() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                self?.refreshAfterEvent()
                if satisfied { self?.restoreIfArmed() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "conduit.network.path"))
        pathMonitor = monitor
    }

    /// Waits for a path *update* reporting satisfaction rather than reading the
    /// current path at wake, because the value standing there at that instant
    /// describes the network the machine had before it slept. Whether this is
    /// late enough is the open question the design rests on: satisfied means a
    /// usable route exists, which is not quite the same as every layer above it
    /// being ready. It is the earliest deterministic signal available, and the
    /// alternative is a number chosen by feel.
    private func restoreIfArmed() {
        guard restorePending, !restoreInFlight else { return }

        // Never interrupt an attempt that is still going. Establishing a tunnel
        // generates path events, so without this the event raised by attempt
        // one arriving would start attempt two, whose disconnect would tear
        // down the tunnel attempt one was most of the way through building —
        // a retry that destroys its own work, repeating until the cap.
        //
        // Asking whether it is still *moving* rather than merely transitional
        // is what makes the retry reachable at all. An abandoned attempt is
        // transitional for ten minutes, so testing that would decline every
        // retry for the whole timeout — the retry would exist and never run.
        let configured = ConduitConfig.seconds("connect-timeout")
        let window = configured > 0 ? configured : 120
        if restoreWanted.contains(where: { name in
            profiles.first { $0.name == name }?.isSettling(within: window) ?? false
        }) {
            // Debug rather than notice: this fires once per path event during
            // an attempt — four times in a normal wake — and says only that a
            // guard did its job. It stays because it is the evidence if the
            // retry ever misbehaves, but it does not belong in the persisted
            // record of what happened.
            Self.log.debug("attempt still settling: not interrupting")
            return
        }
        guard restoreAttempts < restoreMaxAttempts else {
            Self.log.error(
                "restore gave up after \(self.restoreAttempts, privacy: .public) attempts"
            )
            for name in restoreWanted.sorted() {
                Notifier.post(
                    title: "\(name) did not come back",
                    body: "It was connected before your Mac slept."
                )
            }
            restorePending = false
            return
        }
        restoreAttempts += 1
        restoreInFlight = true
        Self.log.notice(
            "path satisfied: attempt \(self.restoreAttempts, privacy: .public)"
        )
        Task { await restore() }
    }

    /// One pass over everything still wanted. Called again by the next
    /// satisfied path event if a poll has not yet seen the tunnel appear.
    private func restore() async {
        defer { restoreInFlight = false }

        // Deliberately no "is it already connected?" check here. For the first
        // seconds after a wake there is no trustworthy answer to that question:
        // the store's own copy is the pre-sleep reading, and the client's is
        // stale too — measured, it went on reporting Connected for six seconds
        // with the network gone the entire time. A check against either one
        // concludes the tunnel survived and stands down, which is exactly what
        // happened and why nothing was restored.
        //
        // So the sequence just runs. It is idempotent in outcome — the profile
        // ends up connected either way — and the only thing it costs, in the
        // narrow case where the connection genuinely did come back on its own
        // first, is rebuilding a tunnel that was seconds old.
        for name in restoreWanted.sorted() {
            activeAttempts.insert(name)
            defer { activeAttempts.remove(name) }

            // Exclusive here too, so a restore cannot be the one path that
            // leaves two tunnels up. In practice this releases nothing: only
            // one profile can be connected, so only one can have been
            // remembered.
            await client.releaseOthers(except: name)

            // Release first. A stalled attempt holds the profile against any
            // replacement, and this is the only thing that clears it. Harmless
            // when the profile is genuinely idle, which is why it is not worth
            // branching on a status that may be seconds out of date anyway.
            do {
                try await client.disconnect(profile: name)
                Self.log.notice("released a held profile")
            } catch {
                // Expected when the profile was simply idle.
                Self.log.notice("nothing to release")
            }

            // No carve-out for sensitive profiles. The confirmation gate exists
            // to stop one being *established* without deliberate intent; this
            // restores intent already expressed, and sleep is an interruption
            // rather than a decision to disconnect. Skipping them would also
            // make "am I on the VPN after sleep?" depend on which VPN, with the
            // exception landing on the one where being wrong costs most.
            do {
                try await client.connect(profile: name)
                Self.log.notice("connect accepted")
            } catch {
                Self.log.error(
                    "connect refused: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        Self.log.notice("restore finished")
        refreshNow()
    }

    /// The monitor reports every path update, and most say nothing about
    /// whether a tunnel exists. Left completely unfiltered they drove the poll
    /// rate instead of the interval doing it — measured at one look every
    /// twenty seconds while nominally idling at sixty.
    ///
    /// Filtering them by which interfaces exist was tried and was much worse.
    /// These tunnels are split: they add routes without becoming the default
    /// route, and `availableInterfaces` never lists them — it reported the
    /// same single interface across eight updates spanning a full connect and
    /// disconnect. Every event was discarded, so nothing triggered a look at
    /// all, and a resting interval was then justified by a safety net that had
    /// quietly been removed. A connection made elsewhere lived and died
    /// entirely between two polls and never appeared.
    ///
    /// So the filter is on time rather than on identity. The volume was the
    /// problem; the signal was always good. An extra look costs one query, and
    /// a missed one costs the thing this application is for.
    /// Coalesces bursts. Interfaces can appear and disappear several times
    /// while a tunnel establishes, and each of those is the same news.
    private func refreshAfterEvent() {
        let now = Date()
        guard now.timeIntervalSince(lastEventRefresh) >= eventRefreshMinimumGap
        else { return }
        lastEventRefresh = now
        refreshNow()
    }
}
