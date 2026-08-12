import Foundation

/// The tabs of the settings window, and which settings each one owns.
///
/// Grouping lives here rather than in the views because it is the one part of
/// a generated form that has to be decided by a person: a card called
/// "Polling" is a judgement about what belongs together, not something a key
/// list can imply. Everything else — the fields, their controls, their
/// descriptions — is still generated, so adding a setting means naming the
/// group it belongs to and nothing more.
///
/// Every key is owned by exactly one group, and the check target asserts that
/// against the real key list. Without it the failure is silent and specific:
/// the setting exists, both surfaces read it, and only this window cannot see
/// it — which is exactly the drift a hand-written form suffers from.
///
/// Foundation-only on purpose. This lives in the model layer so the sandboxed
/// check can compile it, which is what makes the completeness assertion
/// possible at all.
enum SettingsTab: String, CaseIterable, Sendable {
    case general
    case connections
    case safety
    case logs
    case client

    var title: String {
        switch self {
        case .general: return "General"
        case .connections: return "Connections"
        case .safety: return "Safety"
        case .logs: return "Logs"
        case .client: return "Client"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gear"
        case .connections: return "bolt.horizontal"
        // The same mark the panel puts on a row that needs saying yes out
        // loud. Taken from the rule rather than spelled again here, so the
        // tab and the row cannot come to disagree about what it looks like.
        case .safety: return Sensitivity.markSymbolName
        case .logs: return "doc.text"
        // The same glyph Galaxy and assist-ant give their Terminal tab. What
        // this tab configures is where the vendor's command-line binary lives
        // and what it runs with, so a terminal says it and a folder only says
        // "paths", which is the shape of the fields rather than their subject.
        case .client: return "apple.terminal"
        }
    }

    /// One card in the tab. A nil title is a bare card, for a group whose
    /// heading would only repeat the tab's own name.
    struct Group: Sendable {
        let title: String?
        let keys: [String]
    }

    var groups: [Group] {
        switch self {
        case .general:
            return [
                Group(title: "Appearance", keys: ["theme"]),
                Group(title: "After sleep", keys: ["restore-on-wake"]),
            ]

        case .connections:
            return [
                Group(
                    title: "Attempts",
                    keys: [
                        "connect-timeout",
                        "identity-hint-after",
                        "connect-grace-polls",
                    ]
                ),
                Group(
                    title: "Polling",
                    keys: ["poll-interval-active", "poll-interval-idle"]
                ),
            ]

        case .safety:
            return [
                Group(title: nil, keys: ["sensitive-profile-pattern"])
            ]

        case .logs:
            return [
                Group(
                    title: "The client's own logs",
                    keys: ["log-retention-days", "log-max-megabytes"]
                )
            ]

        case .client:
            return [
                Group(title: nil, keys: ["client-path", "client-home"])
            ]
        }
    }

    var keys: [String] { groups.flatMap(\.keys) }

    /// Every settings key, in tab order. Compared against the real key list by
    /// the check target, in both directions: a setting nothing owns would be
    /// invisible here, and a name owned by a tab but absent from the key list
    /// is a typo that would render an empty field.
    static var ownedKeys: [String] { allCases.flatMap(\.keys) }
}
