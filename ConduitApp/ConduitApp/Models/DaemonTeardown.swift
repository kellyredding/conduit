import Foundation

/// Why the client last ended a session, as the client itself said so.
///
/// This is the one thing in the model layer that reports a *cause*. The
/// activity log refuses to, for good reasons that still hold — it watches the
/// connection listing, where a tunnel torn down from a terminal and one that
/// collapsed are indistinguishable, and a guess mixed in there would devalue
/// every observation beside it. This is not that: the daemon writes the reason
/// in plain words, and reading it is measurement rather than inference.
///
/// Nothing here is persisted or logged. The daemon's log is full of profile
/// names, endpoint certificates, routed ranges and challenge tokens, so what
/// is taken from it reaches the screen and stops there.
struct DaemonTeardown: Equatable, Sendable {
    enum Cause: String, Equatable, Sendable {
        /// A local subnet appeared while a tunnel was up and the client stopped
        /// the session by design. Container networks do this: one that comes and
        /// goes takes the tunnel with it every time it arrives.
        case localNetworkChanged

        /// A reconnect drew a fresh identity challenge, which only a person at
        /// a browser can answer. The automatic retry cannot, so the attempt
        /// parks and stays parked.
        case signInRequired

        /// The address the tunnel came up on was not the one expected. See
        /// `network.cr` — a synthesizing network provokes this.
        case serverAddressRejected
    }

    let at: Date
    let cause: Cause
    let profile: String?

    /// Whether a new sign-in is now needed. Carried beside the cause rather
    /// than being one, because in the case that matters it is the *consequence*
    /// — a local network change ends the session, and the reconnect that
    /// follows is what demands the sign-in. A reader deciding what to fix needs
    /// the first of those, not the second.
    let needsSignIn: Bool

    func age(now: Date = Date()) -> TimeInterval { now.timeIntervalSince(at) }
}

/// Finds and reads the daemon's newest log.
///
/// Separate from the parsing so the parsing can be checked against text, and
/// so this can be checked against a temporary directory. The sandboxed check
/// denies subprocesses but not files, which is what makes the whole path
/// reachable rather than only its middle.
enum DaemonLog {
    /// Enough to cover a working day of sessions without reading a file that
    /// has been growing since the client was installed. The scan only ever
    /// wants the most recent teardown.
    static let tailBytes = 512 * 1024

    /// Only the current file, never a rotation.
    ///
    /// The number in `aws_vpn_client_daemon_20260830.log` looks like a date and
    /// is not one — it did not change across eight days of observed rotation,
    /// so it tracks the installation rather than the day. Building the name
    /// from today's date finds nothing. Rotations are `.log.1` and up, whose
    /// extension is the digit, so matching on a `log` extension takes the live
    /// file and leaves the history alone.
    static func newest(
        in directory: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        guard
            let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey]
            )
        else { return nil }

        return entries
            .filter {
                $0.lastPathComponent.hasPrefix("aws_vpn_client_daemon")
                    && $0.pathExtension == "log"
            }
            .max { left, right in
                modified(left, fileManager) < modified(right, fileManager)
            }
    }

    private static func modified(_ url: URL, _ fileManager: FileManager) -> Date {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return (attributes?[.modificationDate] as? Date) ?? .distantPast
    }

    /// The last `bytes` of a file, as text.
    ///
    /// Decoded leniently and with the first line dropped when the read started
    /// mid-file: an offset chosen in bytes lands in the middle of a line and
    /// can land in the middle of a character, and a partial first line is not
    /// worth parsing.
    static func tail(of file: URL, bytes: Int = tailBytes) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return nil
        }
        defer { try? handle.close() }

        guard let end = try? handle.seekToEnd() else { return nil }
        let window = UInt64(max(bytes, 0))
        let start = end > window ? end - window : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }

        let text = String(decoding: data, as: UTF8.self)
        guard start > 0, let newline = text.firstIndex(of: "\n") else {
            return text
        }
        return String(text[text.index(after: newline)...])
    }

    /// The newest teardown the daemon has recorded, if any.
    static func latestTeardown(
        in directory: URL,
        fileManager: FileManager = .default
    ) -> DaemonTeardown? {
        guard
            let file = newest(in: directory, fileManager: fileManager),
            let text = tail(of: file)
        else { return nil }
        return DaemonTeardownParser.latest(fromDaemonLog: text)
    }
}

enum DaemonTeardownParser {
    /// Markers, verified against a real log rather than a document.
    ///
    /// `AUTH_FAILED` is deliberately **not** among them, and this is the whole
    /// subtlety of the file. It is how a federated sign-in *begins*: the server
    /// answers a first connect with a challenge, the client reports
    /// `AUTH_FAILED` and a `DYNAMIC_CHALLENGE`, a browser opens, and the retry
    /// succeeds seconds later. Observed on a connect that went on to work
    /// perfectly. Matching it would report a failure on every healthy tunnel.
    ///
    /// What separates the two is the state the transition came *from*.
    /// `Connecting → WaitingForIdentity` is a sign-in starting normally.
    /// `Reconnecting → WaitingForIdentity` is an automatic retry meeting a
    /// challenge it has no way to answer, which is the case worth reporting.
    private static let localNetwork = "new LAN detected, stopping session"
    private static let reconnectNeedsIdentity =
        "old_state=Reconnecting new_state=WaitingForIdentity"
    private static let addressRejected = "ServerIpValidationFailed"

    /// A local network change and the sign-in demand it causes arrive within a
    /// couple of seconds of each other. Generous next to that, and far short of
    /// the gap between unrelated sessions.
    private static let consequenceWindow: TimeInterval = 120

    /// How far back to look. Bounded so a long file cannot turn this into work
    /// proportional to the client's whole history.
    private static let maxLines = 20_000

    static func latest(fromDaemonLog text: String) -> DaemonTeardown? {
        var found: DaemonTeardown?
        /// The nearest profile *below* the line being examined. Scanning upward
        /// means these were visited already, which is what makes them available
        /// — the line that names the cause often carries no profile of its own,
        /// because it comes from the network watcher rather than a connection.
        var profileBelow: String?
        var scanned = 0

        for line in text.split(
            separator: "\n", omittingEmptySubsequences: true
        ).reversed() {
            scanned += 1
            if scanned > maxLines { break }

            let entry = String(line)
            let profileHere = profile(in: entry)
            defer { profileBelow = profileHere ?? profileBelow }

            guard let cause = cause(in: entry), let at = timestamp(in: entry)
            else { continue }

            guard let already = found else {
                found = DaemonTeardown(
                    at: at,
                    cause: cause,
                    profile: profileHere ?? profileBelow,
                    needsSignIn: cause == .signInRequired
                )
                continue
            }

            // Having found the most recent marker, keep going a little further
            // back for the thing that *started* it. A sign-in demand is the
            // visible end of a local network change, and reporting the demand
            // alone sends a reader to fix the wrong thing.
            //
            // Bounded by time rather than by the next marker: a teardown emits
            // several transitions, so stopping at the first one that is not a
            // local network change would usually stop on a sibling of the one
            // already found.
            if already.at.timeIntervalSince(at) > consequenceWindow { break }

            if already.cause == .signInRequired, cause == .localNetworkChanged {
                found = DaemonTeardown(
                    at: at,
                    cause: .localNetworkChanged,
                    profile: profileHere ?? already.profile,
                    needsSignIn: true
                )
                break
            }
        }

        return found
    }

    private static func cause(in line: String) -> DaemonTeardown.Cause? {
        if line.contains(localNetwork) { return .localNetworkChanged }
        if line.contains(reconnectNeedsIdentity) { return .signInRequired }
        if line.contains(addressRejected) { return .serverAddressRejected }
        return nil
    }

    /// `profile=Alpha`, to the next space or the end of the line.
    private static func profile(in line: String) -> String? {
        guard let marker = line.range(of: "profile=") else { return nil }
        let rest = line[marker.upperBound...]
        let name = rest.prefix { !$0.isWhitespace }
        return name.isEmpty ? nil : String(name)
    }

    /// The leading instant, which carries fractional seconds — so this needs
    /// an option `ProfileState.parse` does not, and cannot simply call it.
    private static func timestamp(in line: String) -> Date? {
        guard let field = line.split(separator: " ").first else { return nil }
        return formatter.date(from: String(field))
    }

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
