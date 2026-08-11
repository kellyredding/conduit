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
    case sensitive
    case error

    /// Two of these are load-bearing and should not be swapped casually.
    ///
    /// `idle` is an outline because nothing is connected for most of the day,
    /// making it the glyph on screen almost always; a loud idle state is noise
    /// the user cannot dismiss.
    ///
    /// `connecting` carries a clock rather than a spinner or another bolt,
    /// because a clock reads as waiting on something external — which is
    /// exactly what the sign-in state is, and the only state where doing
    /// nothing is the correct response.
    var symbolName: String {
        switch self {
        case .idle: return "bolt.slash"
        case .connecting: return "bolt.badge.clock"
        case .connected: return "bolt.fill"
        case .sensitive: return "bolt.shield.fill"
        case .error: return "bolt.trianglebadge.exclamationmark.fill"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .idle: return "No VPN connection"
        case .connecting: return "VPN connecting"
        case .connected: return "VPN connected"
        case .sensitive: return "VPN connected to a sensitive profile"
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
    /// Highest wins.
    ///
    /// `connecting` outranks `sensitive` because it is transient and resolves
    /// within seconds, while a sensitive tunnel persists and reasserts itself
    /// the moment the attempt settles. Ordering them the other way would leave
    /// the bar showing a steady state during the one window where something is
    /// actively changing.
    static func state(
        for profiles: [ProfileState],
        health: ClientHealth
    ) -> MenuIconState {
        if health.isUnavailable { return .error }
        if profiles.contains(where: \.isInFlight) { return .connecting }
        if profiles.contains(where: { $0.isConnected && $0.isSensitive }) {
            return .sensitive
        }
        if profiles.contains(where: \.isConnected) { return .connected }
        return .idle
    }
}
