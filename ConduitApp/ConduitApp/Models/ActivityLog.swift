import Foundation

/// What was observed, in the order it was observed.
///
/// This records *transitions the store actually saw* — a profile that appeared
/// in the connection listing, one that left it, and the client itself becoming
/// unreachable or answering again. It deliberately holds no conclusions: not
/// whether an attempt failed, not why a tunnel ended. The client reports no
/// reason, a tunnel torn down from a terminal is indistinguishable from one that
/// collapsed (measured twice), and a list that mixed observations with guesses
/// would make the observations unreadable too.
///
/// The client's availability belongs here for a reason that is easy to miss: it
/// explains the *holes*. A quiet stretch means nothing was happening only if
/// something was watching, and without those entries an outage looks exactly
/// like an idle afternoon.
///
/// **In memory only, and not persisted.** Two reasons, both deliberate. A log on
/// disk would write profile names into a file, in a project that keeps them out
/// of source, out of the unified log, and out of notifications' own records. And
/// a relaunched Conduit would either show an empty history or one it never
/// witnessed — the same reasoning that stops a restore resurrecting a tunnel the
/// process never saw go down.
struct ActivityLog: Equatable, Sendable {
    /// Enough to cover a working day of ordinary use at a handful of transitions
    /// an hour, and bounded because nothing prunes a process that runs for weeks.
    static let defaultCapacity = 200

    /// Newest first: the window reads top-down and the interesting end is the
    /// recent one.
    private(set) var entries: [ActivityEntry] = []

    let capacity: Int

    init(capacity: Int = ActivityLog.defaultCapacity) {
        self.capacity = capacity
    }

    var isEmpty: Bool { entries.isEmpty }

    mutating func record(_ kind: ActivityEntry.Kind, profile: String? = nil, at: Date) {
        entries.insert(
            ActivityEntry(at: at, kind: kind, profile: profile),
            at: 0
        )
        if entries.count > capacity {
            entries.removeLast(entries.count - capacity)
        }
    }
}

struct ActivityEntry: Equatable, Sendable, Identifiable {
    /// Named for what was seen, never for what it means. "disconnected" is true
    /// whether a person did it or the tunnel collapsed; "dropped" would be a
    /// guess that is wrong regularly and teaches a reader to distrust the rest
    /// of the list.
    enum Kind: String, Equatable, Sendable {
        case connected
        case disconnected
        case clientUnavailable
        case clientReady

        /// Already up when Conduit started, so no transition was ever observed.
        ///
        /// Worth a line of its own because without it the log reads "nothing
        /// observed yet" beside a live tunnel — true, since a tunnel that was
        /// already established produced no transition to see, and useless,
        /// because it looks like the log is broken rather than like the
        /// connection predates the process. Kept distinct from `connected`
        /// rather than fudged into it: this is a state that was found, not a
        /// change that was witnessed, and the whole list is worth less if one
        /// entry quietly means something different from the others.
        case alreadyConnected
    }

    let at: Date
    let kind: Kind
    let profile: String?

    /// Composed from the fields rather than a fresh UUID, so an entry is equal
    /// to itself across a copy — which is what lets the checks compare whole
    /// logs by value.
    var id: String {
        "\(at.timeIntervalSince1970)|\(kind.rawValue)|\(profile ?? "")"
    }

    /// The same wording the notification uses, so the two cannot describe one
    /// event differently.
    var text: String {
        switch kind {
        case .connected: return "\(profile ?? "A profile") connected"
        case .disconnected: return "\(profile ?? "A profile") disconnected"
        case .alreadyConnected:
            return "\(profile ?? "A profile") was already connected"
        case .clientUnavailable: return "The client stopped answering"
        case .clientReady: return "The client answered again"
        }
    }
}
