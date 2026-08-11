import AppKit
import Foundation
import Network

/// What the menu bar knows, kept current by polling.
///
/// **Read-only.** This store cannot start or stop a connection, because the
/// client it holds exposes no way to. That is a property of the types rather
/// than a matter of care, so it cannot lapse by accident.
///
/// The governing idea is reconciliation, not ownership. Conduit is never the
/// only actor: connections are made and torn down from terminals and by other
/// tools, and one is often already live when this launches. So the store
/// renders whatever the client reports and never assumes a state because it
/// asked for one.
@MainActor
final class VPNStore: ObservableObject {
    static let shared = VPNStore()

    @Published private(set) var profiles: [ProfileState] = []
    @Published private(set) var health: ClientHealth = .unknown
    @Published private(set) var lastUpdated: Date?

    /// Only populated while the menu is open. Nobody can see a byte count in a
    /// closed menu, and fetching it costs one subprocess per live tunnel.
    @Published private(set) var counters: [String: VPNByteCounters] = [:]

    var iconState: MenuIconState {
        MenuIcon.state(for: profiles, health: health)
    }

    private let client: VPNClient
    private var pollTask: Task<Void, Never>?
    private var menuIsOpen = false
    private var pathMonitor: NWPathMonitor?
    private var observers: [NSObjectProtocol] = []

    /// The profile listing, cached. Which profiles exist changes only when one
    /// is imported or removed — never by this application, and rarely at all —
    /// while which are connected changes constantly. Re-reading both at the
    /// idle rate would double the subprocess count for an answer that is
    /// almost always identical to the last one.
    private var knownProfiles: [VPNProfile] = []
    private var profilesReadAt: Date?
    private let profileMaxAge: TimeInterval = 60

    init(client: VPNClient? = nil) {
        self.client = client ?? VPNClient.fromConfiguration()
    }

    // MARK: - Lifecycle

    func start() {
        guard pollTask == nil else { return }
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

    private var interval: TimeInterval {
        let name = menuIsOpen || profiles.contains(where: \.isInFlight)
            ? "poll-interval-active"
            : "poll-interval-idle"
        let seconds = ConduitConfig.seconds(name)
        return seconds > 0 ? seconds : 5
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
        counters.removeAll()
        Task { await client.cancelAll() }
        restartPolling()
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
            health = .ready
            lastUpdated = Date()

            if menuIsOpen {
                await refreshCounters()
            }
        } catch is CancellationError {
            return
        } catch {
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

    private func refreshCounters() async {
        for profile in profiles where profile.isConnected {
            guard !Task.isCancelled else { return }
            if let status = try? await client.status(
                profile: profile.name,
                details: true
            ), let details = status.attempt?.details {
                counters[profile.name] = details
            }
        }
    }

    // MARK: - Triggers

    private func observeWake() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(
            center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // Status after a wake is the least trustworthy reading there
                // is: the tunnel may have died while the machine slept and
                // nothing will announce it.
                Task { @MainActor in self?.refreshNow() }
            }
        )
    }

    private func observeNetwork() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        }
        monitor.start(queue: DispatchQueue(label: "conduit.network.path"))
        pathMonitor = monitor
    }
}
