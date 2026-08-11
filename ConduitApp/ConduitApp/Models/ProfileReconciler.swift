import Foundation

/// Turns what the client reports into what the menu shows.
///
/// The client answers two questions separately — which profiles exist, and
/// which connections are live — and only non-disconnected profiles appear in
/// the second. Joining them is the whole job, and the join is where the useful
/// inference lives: absence from the connection listing *is* the answer that a
/// profile is not connected, not a gap to be filled by asking again.
///
/// Kept as a free function over plain values rather than folded into the store
/// so it can be exercised without a subprocess, a timer, or a menu.
enum ProfileReconciler {
    static func states(
        profiles: [VPNProfile],
        connections: [VPNConnection],
        isSensitive: (String) -> Bool = Sensitivity.isSensitive
    ) -> [ProfileState] {
        var byName: [String: VPNConnection] = [:]
        for connection in connections {
            byName[connection.name] = connection
        }

        return profiles.map { profile in
            let connection = byName[profile.name]
            return ProfileState(
                name: profile.name,
                // A connection whose state this build cannot name keeps a nil
                // status and its raw text, rather than being flattened into
                // "not connected" — which would report the opposite of a live
                // tunnel during whatever the client added.
                status: connection == nil ? .notConnected : connection?.status,
                rawStatus: connection?.rawStatus ?? VPNStatus.notConnected.rawValue,
                updatedAt: connection?.updatedAt,
                isSensitive: isSensitive(profile.name)
            )
        }
    }

    /// A connection the client reports for a profile that no longer exists.
    /// Rare, but the alternative to surfacing it is a live tunnel invisible in
    /// the menu, which is the worst thing this application could do.
    static func orphanedConnections(
        profiles: [VPNProfile],
        connections: [VPNConnection]
    ) -> [VPNConnection] {
        let known = Set(profiles.map(\.name))
        return connections.filter { !known.contains($0.name) }
    }
}
