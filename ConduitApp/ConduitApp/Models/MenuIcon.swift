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

    /// The three states seen daily share one shape, the horizontal bolt, and
    /// differ by treatment: hollow, ringed, filled. Holding the family
    /// constant is what makes a change in the bar register as a change in
    /// state rather than as a different icon appearing.
    ///
    /// Two things about this set are known rather than accidental.
    ///
    /// **`idle` and `connected` differ only by weight** — a hollow horizontal
    /// bolt against a filled one — and that is the weakest separation in the
    /// set, on the most important question it answers. It was chosen anyway,
    /// for family consistency, over sets that broke the shape to gain a
    /// stronger contrast. If it proves hard to read in practice the fix is
    /// this table, not a redesign.
    ///
    /// **`sensitive` and `error` leave the family**, because they have to: the
    /// horizontal variants stop at `.circle`, with no shield and no error
    /// badge in that orientation. Both are rare states, so the inconsistency
    /// falls where it is least often seen.
    var symbolName: String {
        switch self {
        case .idle: return "bolt.horizontal"
        case .connecting: return "bolt.horizontal.circle"
        case .connected: return "bolt.horizontal.fill"
        case .sensitive: return "bolt.shield.fill"
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
