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
    private static let route = URL(fileURLWithPath: "/sbin/route")

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
            resolvers: await attachReach(to: await resolvers),
            teardown: teardown(),
            readAt: now
        )
    }

    /// The daemon's own account of why it last ended a session.
    ///
    /// A file read rather than a subprocess, so it belongs here on cost as well
    /// as on subject: it is another read-only look at state Conduit does not
    /// own, wanted on exactly the same event as the routes, and cheaper than
    /// either command beside it.
    ///
    /// Failure is silent and total, like the two commands above — an absent or
    /// unreadable log leaves the window with nothing to say about causes, which
    /// is the honest answer rather than an error worth showing.
    private func teardown() -> DaemonTeardown? {
        DaemonLog.latestTeardown(in: ConduitPaths.daemonLogDir)
    }

    /// Fills in which interface reaches each nameserver.
    ///
    /// One query per *distinct* address rather than per resolver entry: the same
    /// nameserver is routinely listed several times — once unscoped and again
    /// scoped to an interface — and the routing answer cannot differ between
    /// those listings, since it depends on the address alone.
    ///
    /// Sequential on purpose. The count is bounded by how many resolvers the
    /// machine has, which is single digits, and these are routing-socket lookups
    /// rather than network round-trips.
    private func attachReach(to resolvers: [DNSResolver]) async -> [DNSResolver] {
        let addresses = Set(resolvers.flatMap { $0.nameservers.map(\.address) })
        var reach: [String: String] = [:]
        for address in addresses.sorted() {
            if let interface = await self.interface(reaching: address) {
                reach[address] = interface
            }
        }

        return resolvers.map { resolver in
            var updated = resolver
            for index in updated.nameservers.indices {
                updated.nameservers[index].reachedThrough =
                    reach[updated.nameservers[index].address]
            }
            return updated
        }
    }

    /// The kernel's own answer to where traffic to `address` would go.
    ///
    /// The address is passed as its own argument rather than interpolated into a
    /// command line — there is no shell here — so text taken from the resolver
    /// configuration cannot become anything but one argument.
    ///
    /// The address family has to be named for IPv6 or the lookup fails; both
    /// forms were verified against the live routing table.
    func interface(reaching address: String) async -> String? {
        var arguments = ["-n", "get"]
        if address.contains(":") { arguments.append("-inet6") }
        arguments.append(address)

        guard let text = await capture(Self.route, arguments) else { return nil }
        return TunnelFactsParser.interfaceName(fromRouteGet: text)
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
