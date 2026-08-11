import Foundation

/// Centralized path resolution. Nothing else builds these paths ad-hoc.
/// Every value is env-overridable so checks isolate to temporary directories
/// instead of touching a real installation.
///
/// MIRROR: tools/conduit-vpn/src/conduit_vpn/paths.cr
///
/// `clientHome` deliberately does NOT live here. It is a user-facing setting
/// rather than a fixed layout element — a machine whose home directory sits
/// under file sync has to be able to move it — so it is resolved through
/// ConduitConfig with the rest of the settings.
enum ConduitPaths {
    private static var environment: [String: String] {
        ProcessInfo.processInfo.environment
    }

    static func expand(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    static var root: URL {
        if let override = environment["CONDUIT_ROOT"], !override.isEmpty {
            return expand(override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".conduit")
    }

    static var binDir: URL { root.appendingPathComponent("bin") }

    static var logDir: URL { root.appendingPathComponent("logs") }

    static var configFile: URL {
        if let override = environment["CONDUIT_CONFIG"], !override.isEmpty {
            return expand(override)
        }
        return root.appendingPathComponent("config.json")
    }

    /// Documents every setting. Written at install time and never read back —
    /// the resolver treats an absent config file as "everything is default",
    /// so a file that merely restated the defaults would shadow later
    /// improvements to them.
    static var exampleConfigFile: URL {
        root.appendingPathComponent("config.example.json")
    }
}
