import Foundation

/// Reads tunnel state from the operating system rather than from the client.
///
/// Both commands are read-only, cheap, and answer questions the client cannot:
/// which tunnel interfaces exist, what they route, and which resolvers are bound
/// to them. Neither is asked on a timer — the facts change when a tunnel appears
/// or goes away, which is an event the store already observes, so polling them
/// would spend two subprocesses a second to re-read an answer that changes twice
/// a day.
///
/// Foundation-only, so it compiles into the sandboxed check with the rest of the
/// model layer. It is not *exercised* there: the sandbox denies subprocesses,
/// and the parsing it would exercise is already covered directly against
/// fixtures.
actor SystemProbe {
    /// Absolute paths rather than a PATH lookup. A menu bar application launched
    /// by launchd inherits whatever environment launchd had, which is not the
    /// one a shell would give it, and resolving a name against that is how a
    /// feature works when run from a terminal and silently does nothing when run
    /// as a login item.
    private static let netstat = URL(fileURLWithPath: "/usr/sbin/netstat")
    private static let scutil = URL(fileURLWithPath: "/usr/sbin/scutil")

    /// Short by design. These are local queries against kernel state; one that
    /// has not answered in five seconds is not going to.
    private let runner = ProcessRunner(defaultTimeout: 5)

    func read(now: Date = Date()) async -> TunnelFacts {
        // Concurrently, and each failure is contained to its own half: a
        // routing table that could not be read must not also blank the
        // resolvers, because the window would then attribute one command's
        // failure to both and show nothing at all.
        async let routes = self.routes()
        async let resolvers = self.resolvers()

        return TunnelFacts(
            routes: await routes,
            resolvers: await resolvers,
            readAt: now
        )
    }

    private func routes() async -> [TunnelRoute] {
        guard let text = await capture(Self.netstat, ["-rn", "-f", "inet"]) else {
            return []
        }
        return TunnelFactsParser.routes(fromNetstat: text)
    }

    private func resolvers() async -> [DNSResolver] {
        guard let text = await capture(Self.scutil, ["--dns"]) else { return [] }
        return TunnelFactsParser.resolvers(fromScutil: text)
    }

    /// Nil on any failure, deliberately without a reason attached.
    ///
    /// Unlike the client, whose error text is the whole value of a failed call,
    /// these two have nothing to say that a person could act on: they are OS
    /// utilities that either answer or are missing, and a window reporting
    /// "netstat exited 1" above an empty list would be noise where "nothing was
    /// read" is the entire fact.
    private func capture(_ executable: URL, _ arguments: [String]) async -> String? {
        guard
            let data = try? await runner.run(
                executable: executable,
                arguments: arguments
            )
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
