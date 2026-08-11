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
/// are one contract expressed twice, and the CLI and this application read the
/// same file on the same machine. Writing settings lives on the CLI side for
/// now; this side resolves them.
enum ConduitConfig {
    struct Key: Sendable {
        let name: String
        let env: String
        let description: String
        let defaultValue: @Sendable () -> String
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
                Seconds between connection checks at rest, with the menu \
                closed. Only the connection listing is re-read at this rate; \
                the profile listing is far more expensive to no purpose, \
                since it changes only when a profile is imported or removed.
                """,
            defaultValue: { "2" }
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
