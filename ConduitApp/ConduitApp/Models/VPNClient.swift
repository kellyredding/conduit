import Foundation

/// Runs the AWS VPN Client's command-line binary with a corrected HOME.
///
/// MIRROR: tools/conduit-vpn/src/conduit_vpn/client.cr
///
/// The client derives its log directory from HOME as
/// "$HOME/.config/AWSVPNClient/logs" and refuses to start unless that path is
/// free of symlinks anywhere along it. On a machine whose ~/.config is a
/// symlink — a common dotfile-syncing arrangement — it aborts before doing any
/// work, which is why the vendor's own interface cannot run there at all: it is
/// launched by the window server and always inherits the real HOME.
///
/// Nothing else in the client reads HOME. Profiles live under
/// /Library/Application Support and the daemon socket is system-wide, so the
/// override moves only where the client writes its own logs.
actor VPNClient {
    enum Failure: LocalizedError, Equatable {
        case notInstalled(path: String)
        case homeNotCanonical(path: String, resolved: String)
        case commandFailed(String)
        case timedOut(seconds: Int)
        case unreadable

        var errorDescription: String? {
            switch self {
            case .notInstalled(let path):
                return """
                    AWS VPN Client not found at \(path). It ships with client \
                    version 6.0 and later.
                    """
            case .homeNotCanonical(let path, let resolved):
                return """
                    \(path) must be a real directory, not a symlink — it \
                    resolves to \(resolved). The client rejects a log path \
                    containing symlinks and would abort.
                    """
            case .commandFailed(let message):
                return message
            case .timedOut(let seconds):
                return "The client did not answer within \(seconds)s."
            case .unreadable:
                return "The client's response could not be read."
            }
        }
    }

    private let binary: URL
    private let clientHome: URL
    private let runner: ProcessRunner

    init(binary: URL, clientHome: URL, timeout: TimeInterval = 15) {
        self.binary = binary
        self.clientHome = clientHome
        self.runner = ProcessRunner(defaultTimeout: timeout)
    }

    static func fromConfiguration() -> VPNClient {
        VPNClient(
            binary: ConduitConfig.clientPath,
            clientHome: ConduitConfig.clientHome
        )
    }

    /// Terminate any in-flight query. Used when the menu closes and the
    /// answers are no longer wanted.
    func cancelAll() {
        runner.cancelAll()
    }

    // MARK: - Queries
    //
    // Read-only by construction: this type exposes no way to start or stop a
    // connection. Adding one is a deliberate act, not an oversight.

    func listProfiles() async throws -> [VPNProfile] {
        try decode(try await capture(["list-profiles"]), as: VPNPayload.profiles)
    }

    func listConnections() async throws -> [VPNConnection] {
        try decode(
            try await capture(["list-connections"]),
            as: VPNPayload.connections
        )
    }

    func status(
        profile: String,
        details: Bool = false
    ) async throws -> VPNConnectionStatus {
        var arguments = ["get-connection-status", "--profile-name", profile]
        if details { arguments.append("--show-details") }
        return try decode(
            try await capture(arguments),
            as: VPNPayload.connectionStatus
        )
    }

    // MARK: - Invocation

    func capture(_ arguments: [String]) async throws -> Data {
        try ensureInstalled()
        try ensureClientHome()

        do {
            return try await runner.run(
                executable: binary,
                arguments: arguments,
                environment: ["HOME": clientHome.path]
            )
        } catch let error as ProcessRunError {
            throw translate(error)
        }
    }

    /// The client reports failures as a JSON envelope on standard *output* with
    /// a non-zero exit; standard error is empty. Reading only stderr — which is
    /// the ordinary convention, and what a general-purpose runner does — yields
    /// an empty message for every failure the client is capable of reporting.
    private func translate(_ error: ProcessRunError) -> Failure {
        switch error {
        case .launchFailed:
            return .notInstalled(path: binary.path)

        case .timedOut(_, let seconds):
            return .timedOut(seconds: Int(seconds))

        case .exited(_, let status, let standardOutput, let standardError):
            if let message = VPNPayload.errorMessage(standardOutput) {
                return .commandFailed(message)
            }
            let fallback = String(data: standardError, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let fallback, !fallback.isEmpty {
                return .commandFailed(fallback)
            }
            return .commandFailed("The client exited with status \(status).")
        }
    }

    private func decode<T>(_ data: Data, as parse: (Data) throws -> T) throws -> T {
        do {
            return try parse(data)
        } catch {
            throw Failure.unreadable
        }
    }

    // MARK: - Preconditions
    //
    // Checked on every invocation rather than once at launch. The directory can
    // be removed, or acquire a synced parent, at any point while the
    // application is running — and the cost of being wrong is an opaque crash
    // inside the client instead of the sentence above.

    func ensureInstalled() throws {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw Failure.notInstalled(path: binary.path)
        }
    }

    func ensureClientHome() throws {
        let configDirectory = clientHome.appendingPathComponent(".config")

        try? FileManager.default.createDirectory(
            at: configDirectory,
            withIntermediateDirectories: true
        )

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: configDirectory.path,
            isDirectory: &isDirectory
        )
        guard exists, isDirectory.boolValue else {
            throw Failure.homeNotCanonical(
                path: configDirectory.path,
                resolved: "<could not be created>"
            )
        }

        // The literal path against the one the filesystem actually resolves to.
        // They differ exactly when some component is a symlink, which is the
        // condition the client refuses to start under.
        let literal = configDirectory.standardizedFileURL.path
        let resolved = configDirectory.resolvingSymlinksInPath().path

        guard resolved == literal else {
            throw Failure.homeNotCanonical(path: literal, resolved: resolved)
        }
    }
}
