import Foundation

/// Decoders for the AWS VPN Client's JSON output.
///
/// MIRROR: tools/conduit-vpn/src/conduit_vpn/models.cr
///
/// One field the client returns is deliberately absent from every type here:
/// the account that initiated a connection. Conduit has no use for it, and a
/// field that does not exist cannot be printed by accident into a log, an
/// error message, or a screenshot.
enum VPNStatus: String, CaseIterable, Sendable {
    case notConnected = "NotConnected"
    case connecting = "Connecting"
    case waitingForIdentity = "WaitingForIdentity"
    case connected = "Connected"
    case disconnecting = "Disconnecting"
    case reconnecting = "Reconnecting"

    /// The two states the client settles into. Everything else is a
    /// transition that will resolve on its own.
    var isResting: Bool {
        self == .notConnected || self == .connected
    }

    var isTransitional: Bool { !isResting }

    var label: String {
        switch self {
        case .notConnected: return "not connected"
        case .connecting: return "connecting"
        case .waitingForIdentity: return "waiting for sign-in"
        case .connected: return "connected"
        case .disconnecting: return "disconnecting"
        case .reconnecting: return "reconnecting"
        }
    }
}

struct VPNByteCounters: Decodable, Equatable, Sendable {
    let tunnelIn: Int64
    let tunnelOut: Int64
    let transportIn: Int64
    let transportOut: Int64

    enum CodingKeys: String, CodingKey {
        case tunnelIn = "tunnel-bytes-in"
        case tunnelOut = "tunnel-bytes-out"
        case transportIn = "transport-bytes-in"
        case transportOut = "transport-bytes-out"
    }
}

struct VPNAttempt: Decodable, Equatable, Sendable {
    let updatedAt: String?

    /// Absent for an idle profile, and present with every counter zero for a
    /// stalled one — so its presence says nothing about whether a tunnel
    /// exists. Optional rather than zero-defaulted because the client itself
    /// emits the all-zero payload, which a zero default would be
    /// indistinguishable from, and both read as a live tunnel carrying no
    /// traffic.
    let details: VPNByteCounters?

    enum CodingKeys: String, CodingKey {
        case updatedAt = "updated-at"
        case details
    }
}

struct VPNConnectionStatus: Decodable, Equatable, Sendable {
    let rawStatus: String
    let attempt: VPNAttempt?

    enum CodingKeys: String, CodingKey {
        case rawStatus = "connection-status"
        case attempt = "latest-connection-attempt"
    }

    /// Nil for a state this build does not know. A client release that adds
    /// one should leave Conduit reporting something honest rather than
    /// failing to decode the response at all.
    var status: VPNStatus? { VPNStatus(rawValue: rawStatus) }
}

struct VPNProfile: Decodable, Equatable, Sendable {
    let name: String
    let authType: String?
    let importedAt: String?

    enum CodingKeys: String, CodingKey {
        case name = "profile-name"
        case authType = "auth-type"
        case importedAt = "imported-at"
    }
}

/// Only non-disconnected profiles appear in a connection listing, so absence
/// from one is itself the answer: that profile is not connected.
struct VPNConnection: Decodable, Equatable, Sendable {
    let name: String
    let rawStatus: String
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case name = "profile-name"
        case rawStatus = "connection-status"
        case updatedAt = "last-updated-at"
    }

    var status: VPNStatus? { VPNStatus(rawValue: rawStatus) }
}

struct VPNPreferences: Decodable, Equatable, Sendable {
    let maxConnections: Int?

    enum CodingKeys: String, CodingKey {
        case maxConnections = "max-connections"
    }
}

enum VPNPayload {
    private static let decoder = JSONDecoder()

    static func profiles(_ data: Data) throws -> [VPNProfile] {
        try decoder.decode([VPNProfile].self, from: data)
    }

    static func connections(_ data: Data) throws -> [VPNConnection] {
        try decoder.decode([VPNConnection].self, from: data)
    }

    static func connectionStatus(_ data: Data) throws -> VPNConnectionStatus {
        try decoder.decode(VPNConnectionStatus.self, from: data)
    }

    static func preferences(_ data: Data) throws -> VPNPreferences {
        try decoder.decode(VPNPreferences.self, from: data)
    }

    /// The client emits a uniform error envelope — {"status":"Error",
    /// "message":"..."} — on stdout, with a non-zero exit. Reading stderr
    /// finds nothing.
    ///
    /// Returns nil when the payload is not that envelope, so a caller can fall
    /// back to reporting the exit code rather than inventing a message from
    /// output it did not understand.
    static func errorMessage(_ data: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any],
            let message = dictionary["message"] as? String
        else { return nil }
        return message
    }

    static func errorMessage(_ text: String) -> String? {
        guard let data = text.data(using: .utf8) else { return nil }
        return errorMessage(data)
    }
}
