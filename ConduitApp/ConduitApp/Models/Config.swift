import Foundation

/// Settings resolution.
///
///     flag  >  environment variable  >  config file  >  compiled default
///
/// The config file records only what differs from a default. It is never
/// written with the defaults themselves: a file that restated them would
/// freeze the values of its install date, so improving a default in code would
/// silently have no effect on any machine that already ran the installer. An
/// absent, empty, or partial file is the normal case.
///
/// MIRROR: tools/conduit-vpn/src/conduit_vpn/config.cr
///
/// Key names, defaults, and their order must match that file exactly — they
/// are one contract expressed twice, and the CLI and this application read and
/// write the same file on the same machine.
enum ConduitConfig {
    struct Key: Sendable {
        let name: String
        let env: String
        let description: String
        let defaultValue: @Sendable () -> String

        /// The values this setting accepts, when it accepts a fixed set.
        ///
        /// Present on the Swift side only. The command line writes any string
        /// into the file, so a value outside this list is reachable and every
        /// reader of a constrained setting parses leniently rather than
        /// trusting it. What this buys is a picker in the settings window
        /// instead of somebody typing a word that has to match exactly.
        var choices: [String] = []
    }

    enum Source: String, Sendable {
        case `default`, file, env, flag
    }

    struct Resolved: Sendable {
        let key: Key
        let value: String
        let source: Source
    }

    /// Defaults are closures rather than literals because some derive from
    /// other resolved values — the root directory, itself overridable — and so
    /// cannot be known at compile time.
    static let keys: [Key] = [
        Key(
            name: "client-path",
            env: "CONDUIT_CLIENT_PATH",
            description: "Path to the AWS VPN Client command-line binary.",
            defaultValue: {
                "/Applications/AWS VPN Client/AWS VPN Client.app"
                    + "/Contents/MacOS/aws-vpn-client"
            }
        ),
        Key(
            name: "client-home",
            env: "CONDUIT_CLIENT_HOME",
            description: """
                Directory supplied to the client as HOME. Its .config must be a \
                real directory: the client derives its log path from HOME and \
                rejects one containing symlinks.
                """,
            defaultValue: {
                ConduitPaths.root.appendingPathComponent("client-home").path
            }
        ),
        Key(
            name: "sensitive-profile-pattern",
            env: "CONDUIT_SENSITIVE_PATTERN",
            description: """
                Profiles whose name matches this expression need explicit \
                confirmation before connecting. Empty disables the check.
                """,
            defaultValue: { "(?i)prod" }
        ),
        Key(
            name: "poll-interval-active",
            env: "CONDUIT_POLL_ACTIVE",
            description: """
                Seconds between status checks while an attempt is in flight or \
                the menu is open.
                """,
            defaultValue: { "2" }
        ),
        Key(
            name: "poll-interval-idle",
            env: "CONDUIT_POLL_IDLE",
            description: """
                Seconds between connection checks at rest — nothing connected \
                or in flight, and the menu closed, so only the icon is \
                visible. Deliberately slow: a tunnel appearing or vanishing \
                changes the network path, which triggers a check immediately \
                regardless of this, so polling is only the safety net. Every \
                check writes a line to the client's log, which nothing rotates.
                """,
            defaultValue: { "60" }
        ),
        Key(
            name: "connect-timeout",
            env: "CONDUIT_CONNECT_TIMEOUT",
            description: """
                Seconds to keep watching a connection attempt before giving up.
                """,
            defaultValue: { "120" }
        ),
        Key(
            name: "identity-hint-after",
            env: "CONDUIT_IDENTITY_HINT_AFTER",
            description: """
                Seconds to wait in the sign-in state before saying out loud \
                that a browser is waiting.
                """,
            defaultValue: { "15" }
        ),
        Key(
            name: "restore-on-wake",
            env: "CONDUIT_RESTORE_ON_WAKE",
            description: """
                Whether the application re-establishes connections that were \
                live when the machine went to sleep. The client attempts this \
                itself and does it too early, before the network returns, then \
                refuses every subsequent attempt for about ten minutes. Read \
                by the application only; the command line never restores \
                anything.
                """,
            defaultValue: { "true" }
        ),
        Key(
            name: "theme",
            env: "CONDUIT_THEME",
            description: """
                Appearance of the application's own windows: system, light, or \
                dark. Read by the application only; the command line has no \
                windows to theme. Anything unrecognized is treated as system.
                """,
            defaultValue: { "system" },
            choices: ThemePreference.allCases.map(\.rawValue)
        ),
        Key(
            name: "log-retention-days",
            env: "CONDUIT_LOG_RETENTION_DAYS",
            description: """
                Days of the AWS VPN Client's own logs to keep. It writes one \
                file per day and removes none of them; Conduit never reads \
                them. Zero keeps only today's.
                """,
            defaultValue: { "3" }
        ),
        Key(
            name: "log-max-megabytes",
            env: "CONDUIT_LOG_MAX_MB",
            description: """
                Ceiling on the AWS VPN Client's own logs. Oldest are removed \
                first once the total exceeds it, including the current day's \
                if it alone is over — nothing holds these open, so a removed \
                file is recreated on the next query.
                """,
            defaultValue: { "5" }
        ),
        Key(
            name: "connect-grace-polls",
            env: "CONDUIT_CONNECT_GRACE_POLLS",
            description: """
                Consecutive not-connected readings tolerated straight after \
                issuing a connect, before calling it a failure.
                """,
            defaultValue: { "3" }
        ),
    ]

    static func key(named name: String) -> Key? {
        keys.first { $0.name == name }
    }

    static func resolve(
        _ name: String,
        file: [String: String]? = nil
    ) -> Resolved? {
        guard let key = key(named: name) else { return nil }

        if let value = ProcessInfo.processInfo.environment[key.env],
            !value.isEmpty
        {
            return Resolved(key: key, value: value, source: .env)
        }

        let values = file ?? fileValues()
        if let value = values[key.name] {
            return Resolved(key: key, value: value, source: .file)
        }

        return Resolved(key: key, value: key.defaultValue(), source: .default)
    }

    /// Reads the file once and shares it, rather than re-reading per key.
    static func effective() -> [Resolved] {
        let values = fileValues()
        return keys.compactMap { resolve($0.name, file: values) }
    }

    static func get(_ name: String) -> String {
        resolve(name)?.value ?? ""
    }

    static func int(_ name: String) -> Int? {
        Int(get(name))
    }

    static func seconds(_ name: String) -> TimeInterval {
        TimeInterval(int(name) ?? 0)
    }

    /// Anything that is not an explicit denial reads as enabled. A setting
    /// whose default is on should stay on when it is misspelled, because the
    /// alternative is a feature that silently disappears on a typo.
    static func bool(_ name: String) -> Bool {
        !["false", "no", "0", "off"].contains(
            get(name).trimmingCharacters(in: .whitespaces).lowercased()
        )
    }

    /// Path-valued settings are expanded here rather than at each call site, so
    /// a value typed with a leading tilde behaves the same whether it arrived
    /// from a shell (already expanded) or from the config file (not).
    static func path(_ name: String) -> URL {
        ConduitPaths.expand(get(name))
    }

    static var clientPath: URL { path("client-path") }

    static var clientHome: URL { path("client-home") }

    /// A malformed file degrades to defaults rather than aborting. The work
    /// the user actually wants is usually still possible, and a settings file
    /// is a poor reason to refuse to report connection status.
    // MARK: - Writing
    //
    // MIRROR: the command line's own config set / unset. Both write the same
    // file, so the two must agree on what writing one setting does to the
    // rest of it — otherwise editing from one surface quietly discards what
    // was set from the other.
    //
    // Everything already in the file is preserved, including keys this build
    // does not recognize: a settings file written by a newer version must
    // survive being edited by an older one. Only the named key changes.

    enum WriteFailure: LocalizedError {
        case unknownKey(String)

        var errorDescription: String? {
            switch self {
            case .unknownKey(let name):
                return "\(name) is not a setting Conduit knows about."
            }
        }
    }

    static func set(_ name: String, to value: String) throws {
        guard key(named: name) != nil else { throw WriteFailure.unknownKey(name) }
        var object = rawFileObject()
        object[name] = value
        try write(object)
    }

    /// Records a value, or removes it when it is the default.
    ///
    /// The file records only what differs from a default — that is what lets a
    /// default improve in code and take effect on a machine already
    /// configured. Writing the default back into it freezes today's answer,
    /// and does so invisibly, because the value on screen looks identical
    /// either way.
    ///
    /// An empty value means the same thing as choosing the default, which is
    /// what lets a settings field clear to it rather than needing a separate
    /// affordance for going back.
    ///
    /// Distinct from `set` rather than replacing it: the command line writing
    /// a default is a direct instruction and should be honoured literally,
    /// while a form is a place where the default is a resting state.
    static func apply(_ name: String, _ value: String) throws {
        guard let key = key(named: name) else { throw WriteFailure.unknownKey(name) }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == key.defaultValue() {
            try unset(name)
        } else {
            try set(name, to: trimmed)
        }
    }

    static func unset(_ name: String) throws {
        guard key(named: name) != nil else { throw WriteFailure.unknownKey(name) }
        var object = rawFileObject()
        object.removeValue(forKey: name)
        try write(object)
    }

    /// Unfiltered, unlike `fileValues`, which drops anything this build has no
    /// key for. Writing has to carry those through rather than silently
    /// deleting settings it happens not to understand.
    private static func rawFileObject() -> [String: Any] {
        let url = ConduitPaths.configFile
        guard
            let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any]
        else { return [:] }
        return dictionary
    }

    /// Everything back to its compiled defaults.
    ///
    /// Removing the file is the whole implementation, because the file holds
    /// only what differs from a default — so its absence is not a special
    /// empty state to interpret, it is the normal one. That is also why this
    /// cannot half-work: there is no per-key bookkeeping to get out of step.
    static func resetAll() throws {
        let url = ConduitPaths.configFile
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private static func write(_ values: [String: Any]) throws {
        let url = ConduitPaths.configFile

        // Nothing left to record means the file itself should go. An absent
        // file is the documented normal case; a file containing an empty
        // object is the same statement made confusingly, and it invites the
        // question of whether something failed to save.
        if values.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }

        let data = try JSONSerialization.data(
            withJSONObject: values,
            options: [.prettyPrinted, .sortedKeys]
        )
        var text = String(decoding: data, as: UTF8.self)
        // JSONSerialization indents with two spaces, matching the command
        // line, but leaves no trailing newline — and a settings file without
        // one is a nuisance in every terminal that reads it.
        text += "\n"

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func fileValues() -> [String: String] {
        let url = ConduitPaths.configFile
        guard
            let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any]
        else { return [:] }

        var result: [String: String] = [:]
        for (name, value) in dictionary where key(named: name) != nil {
            if let text = value as? String {
                result[name] = text
            } else if let number = value as? NSNumber {
                result[name] = number.stringValue
            }
        }
        return result
    }
}
