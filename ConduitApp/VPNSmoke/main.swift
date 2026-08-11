import Foundation

// Sandboxed smoke check for the model layer: no app launch, no AppKit, no
// subprocess, no network. It exercises decoding, settings resolution, the
// sensitivity rule, and the menu icon reduction against fixtures held here.
//
// `** BUILD SUCCEEDED **` proves none of that. A Swift file full of Codable
// types compiles whether or not its coding keys match what the client actually
// emits, and the failure only appears at runtime as an empty menu.
//
// Profile names here are invented. This repository is public and never carries
// real ones — see CLAUDE.md.

var failures: [String] = []

func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    if condition() {
        print("ok    \(name)")
    } else {
        print("FAIL  \(name)")
        failures.append(name)
    }
}

func data(_ text: String) -> Data { Data(text.utf8) }

// MARK: - Decoding the shapes the client actually emits

let profilesPayload = data(
    """
    [
      {"profile-name": "Alpha", "owned-by": "someone",
       "auth-type": "saml", "imported-at": "2026-01-01T00:00:00-05:00"},
      {"profile-name": "Bravo", "owned-by": "someone",
       "auth-type": "saml", "imported-at": "2026-01-02T00:00:00-05:00"}
    ]
    """
)

let profiles = (try? VPNPayload.profiles(profilesPayload)) ?? []
check("profiles decode", profiles.count == 2)
check("profile name maps from a hyphenated key", profiles.first?.name == "Alpha")

let connectedPayload = data(
    """
    {
      "connection-status": "Connected",
      "latest-connection-attempt": {
        "initiated-by": "someone",
        "updated-at": "2026-01-01T00:00:00-05:00",
        "details": {
          "tunnel-bytes-in": 164676, "tunnel-bytes-out": 1402734,
          "transport-bytes-in": 1487826, "transport-bytes-out": 245520
        }
      }
    }
    """
)

let connected = try? VPNPayload.connectionStatus(connectedPayload)
check("connected status decodes", connected?.status == .connected)
check(
    "byte counters decode",
    connected?.attempt?.details?.tunnelIn == 164_676
)

// Counters must stay absent rather than defaulting to zero: zeroes read as a
// live tunnel that has carried no traffic, which is a different claim.
let idlePayload = data(
    """
    {
      "connection-status": "NotConnected",
      "latest-connection-attempt": {
        "initiated-by": "someone", "updated-at": "2026-01-01T00:00:00-05:00"
      }
    }
    """
)

let idle = try? VPNPayload.connectionStatus(idlePayload)
check("not-connected status decodes", idle?.status == .notConnected)
check("counters stay absent when not connected", idle?.attempt?.details == nil)

let noAttempt = try? VPNPayload.connectionStatus(
    data(#"{"connection-status": "NotConnected"}"#)
)
check("a response with no attempt decodes", noAttempt?.attempt == nil)

// A client release that adds a state should not stop the response decoding.
let unknown = try? VPNPayload.connectionStatus(
    data(#"{"connection-status": "Teleporting"}"#)
)
check("an unknown state still decodes", unknown != nil)
check("an unknown state maps to no case", unknown?.status == nil)
check("an unknown state keeps its text", unknown?.rawStatus == "Teleporting")

let connections = try? VPNPayload.connections(
    data(
        """
        [{"profile-name": "Bravo", "initiated-by": "someone",
          "connection-status": "Connected",
          "last-updated-at": "2026-01-01T00:00:00-05:00"}]
        """
    )
)
check("connections decode", connections?.count == 1)
check("connection status maps", connections?.first?.status == .connected)

check(
    "the error envelope is read from stdout-shaped output",
    VPNPayload.errorMessage(
        data(#"{"status": "Error", "message": "Profile not found"}"#)
    ) == "Profile not found"
)
check(
    "output that is not an envelope yields no message",
    VPNPayload.errorMessage(data("[]")) == nil
)

// MARK: - Status vocabulary

check(
    "resting states are the two the client settles into",
    VPNStatus.notConnected.isResting && VPNStatus.connected.isResting
)
check(
    "every other state is transitional",
    VPNStatus.allCases.filter(\.isTransitional).count == 4
)

// MARK: - Settings mirror

let expectedKeys = [
    "client-path",
    "client-home",
    "sensitive-profile-pattern",
    "poll-interval-active",
    "poll-interval-idle",
    "connect-timeout",
    "identity-hint-after",
    "connect-grace-polls",
]

// Order and spelling both matter: these names are read from a file the CLI
// writes, so a rename on one side silently stops the other from seeing a
// setting at all.
check(
    "settings match the CLI's keys, in order",
    ConduitConfig.keys.map(\.name) == expectedKeys
)
check(
    "an unset setting falls back to its compiled default",
    ConduitConfig.resolve("connect-timeout")?.source == .default
)
check("connect timeout default is 120", ConduitConfig.int("connect-timeout") == 120)
check(
    "the client home derives from the root rather than being fixed",
    ConduitConfig.clientHome.path
        == ConduitPaths.root.appendingPathComponent("client-home").path
)

// MARK: - Sensitivity

check("the default pattern matches a production-ish name", Sensitivity.isSensitive("Prod-Alpha"))
check("the default pattern ignores other names", !Sensitivity.isSensitive("Alpha"))
check("a broken pattern is distinguishable from an empty one", !Sensitivity.patternIsBroken())

// MARK: - Menu icon reduction

func state(_ name: String, _ status: VPNStatus?, sensitive: Bool = false)
    -> ProfileState
{
    ProfileState(
        name: name,
        status: status,
        rawStatus: status?.rawValue ?? "Unknown",
        updatedAt: nil,
        isSensitive: sensitive
    )
}

check(
    "nothing connected reads as idle",
    MenuIcon.state(
        for: [state("Alpha", .notConnected)],
        health: .ready
    ) == .idle
)
check(
    "a live tunnel reads as connected",
    MenuIcon.state(
        for: [state("Alpha", .connected)],
        health: .ready
    ) == .connected
)
check(
    "a sensitive tunnel outranks an ordinary one",
    MenuIcon.state(
        for: [state("Alpha", .connected), state("Prod", .connected, sensitive: true)],
        health: .ready
    ) == .sensitive
)
// Transient, and it resolves in seconds; a steady mark during the one window
// where something is actively changing would be the wrong report.
check(
    "an attempt in flight outranks a sensitive tunnel",
    MenuIcon.state(
        for: [state("Prod", .connected, sensitive: true), state("Alpha", .connecting)],
        health: .ready
    ) == .connecting
)
check(
    "sign-in counts as in flight",
    MenuIcon.state(
        for: [state("Alpha", .waitingForIdentity)],
        health: .ready
    ) == .connecting
)
check(
    "an unreachable client outranks everything",
    MenuIcon.state(
        for: [state("Alpha", .connected)],
        health: .unavailable("no daemon")
    ) == .error
)
check(
    "every state names a distinct symbol",
    Set(MenuIconState.allCases.map(\.symbolName)).count == MenuIconState.allCases.count
)

// MARK: - Result

print("")
if failures.isEmpty {
    print("smoke: all checks passed")
    exit(0)
} else {
    print("smoke: \(failures.count) failed")
    for failure in failures { print("  - \(failure)") }
    exit(1)
}
