import SwiftUI

/// What is actually happening on the tunnels that are up: rates and totals from
/// the client, routes and resolvers from the OS, and the transitions this process
/// observed.
///
/// The panel answers "is it on?" in one glance and has room for nothing else.
/// This is the surface for the questions that need more than a row: how fast,
/// over which interface, resolving through what, and what changed while I was
/// working.
///
/// Built from `SettingsCard` and `SettingsRow` rather than a second set of
/// containers. They are named for where they were first needed, not for what they
/// are, and one card component means the two windows cannot drift into looking
/// like different applications.
struct DetailView: View {
    @ObservedObject var store: VPNStore

    private var connected: [ProfileState] {
        store.profiles.filter(\.isConnected)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                connections
                teardown
                tunnels
                resolvers
                activity
                footer
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Painted explicitly, the same as the panel and the settings window. A
        // hosting view can put its own material between the window and the
        // content, so naming the colour in all three is what keeps them identical.
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Connections

    @ViewBuilder private var connections: some View {
        if connected.isEmpty {
            SettingsCard(title: "Connections") {
                Text("Nothing is connected.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else {
            ForEach(connected, id: \.name) { profile in
                SettingsCard(title: profile.name) {
                    ThroughputChart(
                        series: store.throughput[profile.name] ?? ThroughputSeries()
                    )

                    if let counters = store.counters[profile.name] {
                        Divider()
                        totals(counters)
                    }
                }
            }
        }
    }

    // MARK: - Last teardown

    /// Directly under the connections it explains. Somebody opens this window
    /// because a tunnel vanished, reads the top of it first, and the reason
    /// belongs where the absence is.
    ///
    /// Absent altogether when the client recorded nothing, rather than an empty
    /// card: a heading with "nothing to report" beneath it only invites the
    /// reader to wonder what it would otherwise have said.
    ///
    /// This is the one place the window states a cause. It can, because the
    /// daemon wrote the cause down — everything else here is either a
    /// measurement or an observation, and the activity list below deliberately
    /// draws no conclusions at all.
    @ViewBuilder private var teardown: some View {
        if let teardown = store.facts.teardown {
            SettingsCard(title: "Last teardown") {
                Text(Self.describe(teardown))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                Text(Self.remedy(for: teardown.cause))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }

    /// Leads with the cause and mentions the sign-in second, which is the order
    /// they need acting on: the sign-in demand is downstream of whatever ended
    /// the session, and a reader told only about the sign-in fixes the wrong
    /// thing — repeatedly, since it comes back.
    private static func describe(_ teardown: DaemonTeardown) -> String {
        let when = clock.string(from: teardown.at)
        let who = teardown.profile ?? "A profile"

        var text: String
        switch teardown.cause {
        case .localNetworkChanged:
            text = """
                The client stopped \(who) at \(when) because a new local \
                network appeared.
                """
        case .signInRequired:
            text = """
                \(who) tried to reconnect at \(when) and was asked to sign in \
                again.
                """
        case .serverAddressRejected:
            text = """
                The client stopped \(who) at \(when): it rejected the address \
                the tunnel came up on.
                """
        }

        if teardown.needsSignIn, teardown.cause != .signInRequired {
            text += " The reconnect that followed needs a new sign-in."
        }
        return text
    }

    private static func remedy(for cause: DaemonTeardown.Cause) -> String {
        switch cause {
        case .localNetworkChanged:
            return """
                The client records which local subnets exist when a tunnel \
                comes up and stops the session if a new one appears. A \
                container network that comes and goes will do this every time \
                it arrives; bringing those up before connecting avoids it.
                """
        case .signInRequired:
            return """
                An automatic reconnect cannot answer an identity challenge. \
                Connecting again opens a browser, which can.
                """
        case .serverAddressRejected:
            return """
                A network that synthesizes addresses provokes this. \
                conduit-vpn doctor reports whether this one does.
                """
        }
    }

    /// Both counter pairs, labelled and not explained. The client reports tunnel
    /// and transport totals separately; why they differ is its business, and a
    /// caption inventing a reason would be a guess printed under a heading that
    /// says measurement.
    private func totals(_ counters: VPNByteCounters) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsRow(label: "Tunnel") {
                Text(pair(in: counters.tunnelIn, out: counters.tunnelOut))
                    .monospacedDigit()
                    .font(.callout)
            }
            SettingsRow(label: "Transport") {
                Text(pair(in: counters.transportIn, out: counters.transportOut))
                    .monospacedDigit()
                    .font(.callout)
            }
            // The second sentence is the one that stops the plot above being
            // misread. Every number in this card counts tunnel traffic only, so
            // on a split tunnel a saturated link shows up here as nothing at
            // all — which looks exactly like a broken readout unless it is said
            // out loud.
            Text(
                """
                Cumulative since the attempt started, as the client reports \
                them. Only traffic that crosses the tunnel is counted.
                """
            )
            .font(.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pair(in inbound: Int64, out outbound: Int64) -> String {
        "↓ \(ThroughputFormat.total(inbound))   ↑ \(ThroughputFormat.total(outbound))"
    }

    // MARK: - Tunnel interfaces

    @ViewBuilder private var tunnels: some View {
        SettingsCard(title: "Tunnel interfaces") {
            if !store.facts.hasBeenRead {
                Text("Not read yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if store.facts.interfaces.isEmpty {
                Text("No tunnel interface carries any route.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                // What the tunnel actually carries, read from the routing table
                // rather than asserted. This is the first thing a person wants
                // and the last thing the client will tell them.
                Text(reachDescription)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                // Stated whenever anything is listed, not only when it becomes
                // ambiguous. With one connection the association is obvious to
                // the person reading it and still not something Conduit knows,
                // and a caveat that appears only sometimes reads as a warning
                // about that particular moment rather than as a standing limit.
                Text(
                    """
                    The client does not report which interface belongs to which \
                    profile, so these are listed by interface and not attributed.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                ForEach(store.facts.interfaces, id: \.self) { interface in
                    interfaceRoutes(interface)
                }
            }
        }
    }

    /// Split or full, decided by whether a tunnel holds the default route.
    ///
    /// Both sentences name what was read rather than describing VPNs in general:
    /// a deployment can be configured either way, the answer is in the routing
    /// table, and which one it is changes what every number in this window means.
    private var reachDescription: String {
        if store.facts.carriesDefaultRoute {
            return """
                A tunnel carries the default route, so traffic goes through the \
                VPN unless a more specific route sends it elsewhere.
                """
        }
        return """
            No tunnel carries the default route. Only traffic to the destinations \
            below goes through the VPN — everything else takes your ordinary \
            connection and is not counted above.
            """
    }

    private func interfaceRoutes(_ interface: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(interface)
                .font(.system(size: 11, weight: .semibold))
                .monospaced()

            ForEach(store.facts.routes(on: interface)) { route in
                HStack(spacing: 8) {
                    Text(route.destination)
                        .frame(minWidth: 150, alignment: .leading)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                    Text(route.gateway)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11))
                .monospaced()
                .foregroundStyle(.secondary)
                // Selectable because the whole point of showing an address is
                // that somebody wants to use it somewhere else.
                .textSelection(.enabled)
            }
        }
        .padding(.top, 2)
    }

    // MARK: - Resolvers

    @ViewBuilder private var resolvers: some View {
        SettingsCard(title: "Resolvers") {
            if !store.facts.hasBeenRead {
                Text("Not read yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if store.facts.resolvers.isEmpty {
                Text("No resolver reports a nameserver.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                // Says what the OS reports and stops there. On this deployment
                // nothing is scoped to the tunnel — measured, with a tunnel up —
                // so a list of only tunnel-scoped resolvers was an empty box, and
                // an unscoped resolver serving internal names is indistinguishable
                // here from one that is not.
                Text(
                    """
                    In the order the operating system reports them. Scope is what \
                    it reports too: nothing ties an unscoped resolver to a tunnel, \
                    either way. "via" is the interface the kernel would send \
                    queries through — a packet path, not a statement about which \
                    resolver gets used for a given name.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                ForEach(store.facts.resolvers) { resolver in
                    resolverRow(resolver)
                }
            }
        }
    }

    private func resolverRow(_ resolver: DNSResolver) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(resolver.scopeDescription)
                    .font(.system(size: 11, weight: .semibold))
                    .monospaced()
                // The one case the OS itself ties DNS to the VPN. Marked rather
                // than sorted to the top, because resolver order is part of how
                // a name gets resolved.
                if resolver.isTunnelScoped {
                    Text("tunnel")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
            }

            ForEach(resolver.nameservers) { nameserver in
                HStack(spacing: 8) {
                    Text(nameserver.address)
                        .font(.system(size: 11))
                        .monospaced()
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    // Shown for either answer, because "these queries do not go
                    // through the tunnel" is as much of an answer as the
                    // reverse, and only stated at all when the kernel gave one.
                    if let reach = nameserver.reachedThrough {
                        Text("via \(reach)")
                            .font(.system(size: 9, weight: .semibold))
                            .monospaced()
                            .foregroundStyle(
                                nameserver.isReachedThroughTunnel
                                    ? .primary : .secondary
                            )
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                nameserver.isReachedThroughTunnel
                                    ? AnyShapeStyle(.tertiary)
                                    : AnyShapeStyle(.quinary),
                                in: Capsule()
                            )
                    }
                    Spacer(minLength: 0)
                }
            }

            if !resolver.searchDomains.isEmpty {
                Text("Search: \(resolver.searchDomains.joined(separator: ", "))")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 2)
    }

    // MARK: - Activity

    @ViewBuilder private var activity: some View {
        SettingsCard(title: "Activity") {
            if store.activity.isEmpty {
                Text("Nothing observed yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.activity.entries) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(Self.clock.string(from: entry.at))
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                        Text(entry.text)
                            .font(.system(size: 11))
                        Spacer(minLength: 0)
                    }
                }

                Text("Observed by this process, since it launched. Not saved.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
        }
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            HStack(alignment: .top) {
                Text(readingDescription)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 12)

                Button("Refresh") {
                    store.refreshNow()
                    store.refreshFactsNow()
                }
                .controlSize(.small)
            }
        }
    }

    /// Says when the OS values were read rather than implying they are live.
    /// They refresh when a connection appears or goes away, which can be a long
    /// time ago on a stable tunnel — and a stale reading presented as current is
    /// the failure this whole window is meant to avoid.
    private var readingDescription: String {
        var lines = [
            """
            Rates are sampled only while this window or the menu is open. \
            Routes and resolvers are read from the operating system.
            """
        ]
        if let readAt = store.facts.readAt {
            lines.append("Last read at \(Self.clock.string(from: readAt)).")
        }
        return lines.joined(separator: " ")
    }
}
