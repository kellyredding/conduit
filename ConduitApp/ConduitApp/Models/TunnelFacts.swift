import Foundation

/// What the operating system says about the tunnels currently up.
///
/// The client reports which profiles are connected and how many bytes they have
/// carried, and nothing else about the resulting network. Routes and resolvers
/// come from the OS instead — which is also the only place they may come from in
/// this repository, since a routed range or a resolver address committed to
/// source would describe somebody's particular VPN. Read at runtime, displayed,
/// never stored.
///
/// **The attribution gap.** The client does not report which `utun` interface
/// belongs to which profile, and nothing in the routing table or the resolver
/// configuration carries a profile name either. With one connection the
/// association is unambiguous but still unstated; with several it cannot be
/// recovered at all. So these values are interface-scoped and the interface is
/// as far as the claim goes — the window shows the tunnels that exist without
/// saying whose they are, rather than guessing from an ordering the client never
/// promised.
///
/// Foundation-only: parsing is pure text-to-value, so the sandboxed check
/// exercises it against fixtures with no interface, no VPN, and no privileges.
struct TunnelFacts: Equatable, Sendable {
    var routes: [TunnelRoute] = []
    var resolvers: [DNSResolver] = []

    /// When these were read, so the window can say how current they are rather
    /// than implying they are live. They refresh on events, not on a timer.
    var readAt: Date?

    /// Whether anything has been read yet, which is different from having read
    /// and found nothing.
    var hasBeenRead: Bool { readAt != nil }

    /// Whether a tunnel interface holds the default route — which is the whole
    /// difference between "all traffic goes through the VPN" and "four prefixes
    /// do".
    ///
    /// Worth computing rather than assuming, in both directions. These
    /// deployments are split: measured with a tunnel up, `default` belonged to
    /// the physical interface and every tunnel route was a specific prefix, so a
    /// speed test crossed the tunnel not at all and the throughput plot sat flat
    /// at a couple of hundred bytes per second of keepalive — correctly, and
    /// unreadably, because nothing on screen said what the tunnel was carrying.
    /// A deployment that pushed a default route would make the same plot mean
    /// the opposite thing, so the claim is read from the routing table instead
    /// of being written into a caption.
    ///
    /// `routes` holds tunnel interfaces only, so a default destination here can
    /// only have come from one.
    var carriesDefaultRoute: Bool {
        self.routes.contains { $0.destination == "default" }
    }

    /// Interface names in first-seen order, which for a routing table is
    /// roughly the order the kernel holds them in.
    var interfaces: [String] {
        var seen = Set<String>()
        return self.routes.compactMap { route in
            seen.insert(route.interface).inserted ? route.interface : nil
        }
    }

    func routes(on interface: String) -> [TunnelRoute] {
        self.routes.filter { $0.interface == interface }
    }
}

/// One row of the routing table that a tunnel interface owns.
struct TunnelRoute: Equatable, Sendable, Identifiable {
    let destination: String
    let gateway: String
    let interface: String

    var id: String { "\(interface)|\(destination)|\(gateway)" }
}

/// One resolver the OS is configured with, and whatever it says about scope.
///
/// Listed whether or not it is tied to a tunnel, because on the deployment this
/// was built against *none* of them is: measured with a tunnel up, every resolver
/// named the physical interface and none named `utun4`. A window that showed only
/// tunnel-scoped resolvers was therefore an empty box by construction, and it
/// answered a narrower question than the one worth asking — which is what the
/// machine will actually resolve names with.
///
/// The scope is reported and never inferred. An unscoped resolver may well be
/// serving internal names through the tunnel; nothing here can tell, and saying
/// so is more useful than implying either answer.
struct DNSResolver: Equatable, Sendable, Identifiable {
    /// The interface the OS scoped this resolver to, or nil when it named none.
    let interface: String?
    let nameservers: [String]
    let searchDomains: [String]

    var id: String {
        "\(interface ?? "-")|\(nameservers.joined(separator: ","))"
    }

    /// Bound to a tunnel interface — the one case where the OS itself ties a
    /// resolver to the VPN rather than leaving it to be guessed at.
    var isTunnelScoped: Bool {
        guard let interface else { return false }
        return TunnelFactsParser.isTunnel(interface)
    }

    var scopeDescription: String {
        interface ?? "not scoped to an interface"
    }
}

/// Text-to-value parsing for the two commands, kept apart from the code that
/// runs them so the awkward part is the testable part.
enum TunnelFactsParser {
    /// A tunnel interface, by name. The client names them nothing else, and
    /// matching the name is the only handle available.
    static func isTunnel(_ interface: String) -> Bool {
        interface.hasPrefix("utun")
    }

    // MARK: - Routes

    /// Rows of `netstat -rn -f inet` that belong to a tunnel interface.
    ///
    /// Deliberately does not parse the header or count the columns. A row is
    /// taken only if one of its fields *is* a tunnel interface name, which means
    /// the header lines, the section titles, and the blank lines all fall out
    /// for free — and a future macOS that adds or reorders a column does not
    /// silently start reading the wrong field.
    ///
    /// The **last** matching field is the interface, not the first. On a
    /// point-to-point route the gateway column can itself hold an interface
    /// name, in which case the first match would report the gateway as the
    /// interface. That is inferred from BSD routing conventions rather than
    /// observed here — no tunnel was up when this was written — but taking the
    /// last field is correct in both layouts, so the inference costs nothing if
    /// it is wrong.
    static func routes(fromNetstat text: String) -> [TunnelRoute] {
        text.split(separator: "\n").compactMap { line in
            let fields = line
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init)

            // Destination and gateway occupy the first two fields in every
            // layout this has seen; the interface is located rather than
            // counted to.
            guard
                fields.count >= 3,
                let interfaceIndex = fields.lastIndex(where: isTunnel),
                interfaceIndex >= 2
            else { return nil }

            return TunnelRoute(
                destination: fields[0],
                gateway: fields[1],
                interface: fields[interfaceIndex]
            )
        }
    }

    // MARK: - Resolvers

    /// Every resolver `scutil --dns` reports that has a nameserver to offer.
    ///
    /// The output holds two sections — the resolver list and a second one for
    /// scoped queries — and the resolver numbering **restarts** in the second,
    /// measured. So blocks are keyed by nothing but their own contents, and the
    /// identical entry appearing in both sections is collapsed rather than
    /// listed twice as though two resolvers existed.
    ///
    /// Order is preserved as the OS printed it, deliberately. Resolver order is
    /// part of how names get resolved, so sorting these — tunnel-scoped first,
    /// say — would tidy the display by misrepresenting precedence.
    ///
    /// Blocks with no nameserver are dropped. The output carries several of those
    /// (mDNS and similar, which announce only a domain and some options), and
    /// they have nothing to contribute to "what will this machine resolve names
    /// with".
    static func resolvers(fromScutil text: String) -> [DNSResolver] {
        var found: [DNSResolver] = []
        var nameservers: [String] = []
        var searchDomains: [String] = []
        var interface: String?
        var inBlock = false

        func flush() {
            defer {
                nameservers = []
                searchDomains = []
                interface = nil
            }
            guard !nameservers.isEmpty else { return }
            let resolver = DNSResolver(
                interface: interface,
                nameservers: nameservers,
                searchDomains: searchDomains
            )
            guard !found.contains(resolver) else { return }
            found.append(resolver)
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // Measured format: "resolver #1", renumbered from 1 in the scoped
            // section.
            if line.hasPrefix("resolver #") {
                if inBlock { flush() }
                inBlock = true
                continue
            }

            guard inBlock, let separator = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<separator]
                .trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }

            // Indexed keys — "nameserver[0]", "search domain[1]" — so the
            // prefix is matched and the index ignored: order in the file is the
            // order they are used in, which is what the array preserves.
            if key.hasPrefix("nameserver") {
                nameservers.append(value)
            } else if key.hasPrefix("search domain") {
                searchDomains.append(value)
            } else if key == "if_index" {
                interface = interfaceName(fromIfIndex: value)
            }
        }

        if inBlock { flush() }
        return found
    }

    /// `if_index` reads as `14 (en0)`, measured. The name in parentheses is the
    /// only place the output states which interface a resolver belongs to.
    static func interfaceName(fromIfIndex value: String) -> String? {
        guard
            let open = value.firstIndex(of: "("),
            let close = value.lastIndex(of: ")"),
            open < close
        else { return nil }
        let name = value[value.index(after: open)..<close]
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}
