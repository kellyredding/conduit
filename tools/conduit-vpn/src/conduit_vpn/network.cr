require "socket"

module ConduitVPN
  # What the network is doing to addresses before the client ever sees them.
  #
  # This exists because of one failure that is otherwise unreadable. On a
  # network that synthesizes IPv6 addresses for IPv4-only hosts, the AWS VPN
  # Client connects successfully over the translated address, then compares
  # that address against the one it expected, decides they differ, and tears
  # down its own working tunnel. The two are the same address — the synthesized
  # form embeds the original in its low 32 bits — but the comparison is textual
  # and does not know that.
  #
  # What the user sees is a connection that authenticates, reports itself
  # connected for a fraction of a second, and vanishes. What the log says is
  # `ServerIpValidationFailed`, in a root-owned file. Conduit exists because
  # this client fails inscrutably; leaving this one unexplained would be
  # choosing not to do the job.
  module Network
    extend self

    # RFC 7050. This name has A records and, by definition, no AAAA of its
    # own — so any AAAA answer for it was manufactured by the resolver, which
    # is what DNS64 is. Asking a well-known name is far more reliable than
    # inspecting interfaces or guessing at prefixes.
    IPV4_ONLY_NAME = "ipv4only.arpa"

    # Must go through the system resolver rather than a DNS tool. Synthesis
    # happens inside the resolver, so a query that talks to the nameserver
    # directly sees the truth and misses the lie the applications are told.
    def synthesized_addresses : Array(String)
      Socket::Addrinfo.resolve(
        IPV4_ONLY_NAME, 80,
        family: Socket::Family::INET6,
        type: Socket::Type::STREAM,
      ).map(&.ip_address.address).uniq
    rescue
      # No answer, no resolver, no network: all mean "no evidence of
      # synthesis", which is the useful answer rather than an error.
      [] of String
    end

    def synthesizing_addresses? : Bool
      !synthesized_addresses.empty?
    end

    def summary : String
      addresses = synthesized_addresses
      return "no address synthesis on this network" if addresses.empty?
      "this network synthesizes IPv6 addresses (#{addresses.first})"
    end

    # Deliberately names the fix. A diagnosis the reader cannot act on is only
    # a more precise way of being stuck.
    def synthesis_explanation : String
      <<-TEXT
      This network translates IPv4 for IPv6 clients (NAT64/DNS64), so names
      resolve to synthesized IPv6 addresses that carry the real IPv4 address
      inside them.

      A profile whose transport is "udp" lets the resolver choose, and here it
      chooses the synthesized address. The AWS VPN Client then compares the
      address it connected to against the one it expected, as text, decides
      they differ, and tears down its own working tunnel. Connections
      authenticate, report connected for a fraction of a second, and collapse.

      The fix is one line in the profile. Naming the address family explicitly
      makes the client skip the synthesized candidates and use IPv4, which it
      reports doing rather than failing silently:

        conduit-vpn get-config --profile-name NAME > profile.ovpn
        #   change:  proto udp   ->   proto udp4
        conduit-vpn import-profile --profile-name NAME-ipv4 \\
          --config-path profile.ovpn

      That file contains credentials. Keep it out of shared directories and
      delete it once the profile is imported.

      Turning IPv6 off for the whole machine also works and is worse: it needs
      administrator rights, it affects every other application, and nothing
      restores it if this one stops running.
        networksetup -setv6off "Wi-Fi"
        networksetup -setv6automatic "Wi-Fi"
      TEXT
    end
  end
end
