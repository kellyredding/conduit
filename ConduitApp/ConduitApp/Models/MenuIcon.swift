import Foundation

/// What the menu bar shows, reduced from every profile's state.
///
/// Monochrome by design: the status item image is rendered as a template, so
/// macOS paints it in the menu bar's own foreground colour and it follows the
/// system appearance without a second asset. Every state is separated by shape
/// rather than by weight or colour, which is what keeps them apart at 18pt.
enum MenuIconState: String, CaseIterable, Sendable {
    case idle
    case connecting
    case connected
    case error

    /// The three states seen daily share one shape, the horizontal bolt, and
    /// differ by treatment: hollow, ringed, filled. Holding the family
    /// constant is what makes a change in the bar register as a change in
    /// state rather than as a different icon appearing.
    ///
    /// Two things about this set are known rather than accidental.
    ///
    /// **`idle` and `connected` differ only by weight** — a hollow horizontal
    /// bolt against a filled one. On paper that is the weakest separation in
    /// the set, on the most important question it answers, and sets that broke
    /// the shape to gain contrast were considered and rejected for it. Checked
    /// at size in a real menu bar afterwards, against real neighbours: the
    /// pair reads at a glance and the concern did not survive contact. Kept as
    /// a note because the reasoning would otherwise look like an oversight.
    ///
    /// **`error` leaves the family** because it has to: the horizontal variants
    /// stop at `.circle`, with no error badge in that orientation. It is the
    /// rarest state, so the inconsistency falls where it is least often seen.
    ///
    /// **There is no state here for a sensitive connection.** There was, and
    /// it was removed after looking at it: every candidate either carried its
    /// meaning in interior detail that dies at this size, or gained enough
    /// mass to read only by abandoning the shape the other states share. A
    /// glyph that cannot be told apart is not a state, it is noise wearing
    /// one — and the panel already marks those rows, where there is room to
    /// mark them legibly. See `Sensitivity.markSymbolName`.
    var symbolName: String {
        switch self {
        case .idle: return "bolt.horizontal"
        case .connecting: return "bolt.horizontal.circle"
        case .connected: return "bolt.horizontal.fill"
        case .error: return "bolt.trianglebadge.exclamationmark.fill"
        }
    }

    /// The glyph the application icon is drawn from, so the Dock and the menu
    /// bar are the same shape. Connected is the right one to borrow: it is
    /// what the application is for, and the only state worth depicting when
    /// the icon has to stand for the whole tool.
    static var iconSymbolName: String { MenuIconState.connected.symbolName }

    var accessibilityLabel: String {
        switch self {
        case .idle: return "No VPN connection"
        case .connecting: return "VPN connecting"
        case .connected: return "VPN connected"
        case .error: return "VPN unavailable"
        }
    }
}

/// One profile as the menu understands it. Deliberately not the client's own
/// shape: absence from a connection listing has already been resolved into a
/// state by the time anything reaches here.
struct ProfileState: Equatable, Sendable {
    let name: String
    let status: VPNStatus?
    let rawStatus: String
    let updatedAt: String?
    let isSensitive: Bool

    var label: String { status?.label ?? rawStatus }
    var isConnected: Bool { status == .connected }
    var isInFlight: Bool { status?.isTransitional ?? false }

    /// Whether a transition is plausibly still in motion, as opposed to one the
    /// client has abandoned in place.
    ///
    /// Both look identical in a status response — the only thing separating a
    /// connect that is working from one that is stuck is how long it has sat
    /// there, so a duration is not an arbitrary choice here but the only
    /// available signal. `updated-at` marks the last state *change*, not a
    /// heartbeat, so its age is exactly "how long have we been here".
    ///
    /// The two populations are not close: a connect runs 9–18 seconds end to
    /// end, and an abandoned attempt sits for 598. Any bound between them
    /// behaves the same, which is why this reuses `connect-timeout` — already
    /// defined as the longest an attempt may legitimately take — rather than
    /// introducing a number of its own.
    ///
    /// An unparseable or absent timestamp reads as in motion. Every listed
    /// transitional profile carries one, so this is a fallback for a client
    /// that changes its format, and in that case saying "something is
    /// happening" is the smaller error.
    func isSettling(within seconds: TimeInterval, now: Date = Date()) -> Bool {
        guard isInFlight else { return false }
        guard let updatedAt, let moved = ProfileState.parse(updatedAt) else {
            return true
        }
        return now.timeIntervalSince(moved) <= seconds
    }

    static func parse(_ timestamp: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: timestamp)
    }
}

/// Whether the client itself can be reached at all, which is a different
/// question from what any profile is doing.
enum ClientHealth: Equatable, Sendable {
    case unknown
    case ready
    case unavailable(String)

    var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }
}

enum MenuIcon {
    /// The bar reports connectivity, not activity.
    ///
    /// Exactly one status means a tunnel exists: `Connected`. Every other one —
    /// `NotConnected`, `Connecting`, `WaitingForIdentity`, `Disconnecting`,
    /// `Reconnecting` — means no route, no interface address and no bytes,
    /// verified against the route table during a ten-minute stall. So the bar
    /// is a pure function of that one fact, with no clock in it.
    ///
    /// `settling` outranks a live tunnel, because a settled tunnel will still
    /// be there in two seconds while the window in which something is changing
    /// is the whole of what the bar has to report.
    ///
    /// This briefly keyed on Conduit's own attempts alone, after the settling
    /// glyph was found stuck for ten minutes on a dead tunnel. That fixed the
    /// lie by discarding the signal: a connect started from a terminal — which
    /// is most of them — then showed nothing at all until it completed.
    /// `ProfileState.isSettling` is the version that keeps both, by asking
    /// whether the transition is still moving rather than whether Conduit
    /// started it.
    ///
    /// Sensitivity is deliberately absent. Whether a live tunnel is one that
    /// warranted saying yes to does not change what the bar shows, because no
    /// glyph tested could carry that at this size — the panel says it instead.
    static func state(
        for profiles: [ProfileState],
        health: ClientHealth,
        settling: Bool = false
    ) -> MenuIconState {
        if health.isUnavailable { return .error }
        if settling { return .connecting }
        if profiles.contains(where: \.isConnected) { return .connected }
        return .idle
    }
}
