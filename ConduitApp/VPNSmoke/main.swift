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

// MARK: - Reconciling profiles against connections

func profile(_ name: String) -> VPNProfile {
    let json = #"{"profile-name": "\#(name)"}"#
    return try! VPNPayload.profiles(Data("[\(json)]".utf8))[0]
}

func connection(_ name: String, _ status: String, at stamp: String? = nil) -> VPNConnection {
    var fields = #""profile-name": "\#(name)", "connection-status": "\#(status)""#
    if let stamp { fields += #", "last-updated-at": "\#(stamp)""# }
    return try! VPNPayload.connections(Data("[{\(fields)}]".utf8))[0]
}

let never: (String) -> Bool = { _ in false }

// Absence from the connection listing IS the answer, not a gap to fill by
// asking again.
let reconciled = ProfileReconciler.states(
    profiles: [profile("Alpha"), profile("Bravo"), profile("Charlie")],
    connections: [connection("Bravo", "Connected", at: "2026-01-01T12:00:00-05:00")],
    isSensitive: never
)
check("every profile gets a row", reconciled.count == 3)
check(
    "a profile absent from the listing reads as not connected",
    reconciled.first { $0.name == "Alpha" }?.status == .notConnected
)
check(
    "a listed profile carries its state",
    reconciled.first { $0.name == "Bravo" }?.isConnected == true
)
check(
    "a listed profile carries its timestamp",
    reconciled.first { $0.name == "Bravo" }?.updatedAt != nil
)
check(
    "an absent profile carries no timestamp",
    reconciled.first { $0.name == "Alpha" }?.updatedAt == nil
)
check(
    "row order follows the profile listing, not the connection listing",
    reconciled.map(\.name) == ["Alpha", "Bravo", "Charlie"]
)

// Flattening this to "not connected" would report the opposite of a live
// tunnel for whatever state a future client release adds.
let strange = ProfileReconciler.states(
    profiles: [profile("Alpha")],
    connections: [connection("Alpha", "Teleporting")],
    isSensitive: never
)
check("an unknown live state is not flattened to disconnected", strange[0].status == nil)
check("an unknown live state keeps its text", strange[0].rawStatus == "Teleporting")
check("an unknown live state still reads as in flight", strange[0].isInFlight == false)

// A live tunnel invisible in the menu is the worst thing this app could do.
check(
    "a connection with no matching profile is surfaced, not dropped",
    ProfileReconciler.orphanedConnections(
        profiles: [profile("Alpha")],
        connections: [connection("Ghost", "Connected")]
    ).map(\.name) == ["Ghost"]
)
check(
    "nothing is reported orphaned when every connection has a profile",
    ProfileReconciler.orphanedConnections(
        profiles: [profile("Alpha")],
        connections: [connection("Alpha", "Connected")]
    ).isEmpty
)

check(
    "the sensitivity rule is applied per profile",
    ProfileReconciler.states(
        profiles: [profile("Alpha"), profile("Prod-Bravo")],
        connections: [],
        isSensitive: { $0.hasPrefix("Prod") }
    ).map(\.isSensitive) == [false, true]
)

// MARK: - The subprocess layer, against a fixture client
//
// These are the two behaviors that made a general-purpose runner unusable
// here, so they are checked rather than asserted in a comment: the child must
// receive an overridden HOME, and a failure must surface the message the
// client wrote to standard *output*.

func runBlocking<T>(_ operation: @escaping () async throws -> T) -> Result<T, Error> {
    let semaphore = DispatchSemaphore(value: 0)
    var outcome: Result<T, Error>!
    Task {
        do { outcome = .success(try await operation()) } catch { outcome = .failure(error) }
        semaphore.signal()
    }
    semaphore.wait()
    return outcome
}

let fixtureRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("conduit-smoke-\(ProcessInfo.processInfo.processIdentifier)")
    // Temporary directories here sit behind symlinked parents, and the client
    // home check compares a resolved path against a literal one. Resolving now
    // means the check exercises what a real install looks like rather than
    // failing for a reason that has nothing to do with it.
    .resolvingSymlinksInPath()

try? FileManager.default.createDirectory(
    at: fixtureRoot, withIntermediateDirectories: true
)
defer { try? FileManager.default.removeItem(at: fixtureRoot) }

let callLog = fixtureRoot.appendingPathComponent("calls.log")
let fixtureClient = fixtureRoot.appendingPathComponent("aws-vpn-client")

// Records the HOME it was handed, then answers from the environment. Errors
// go to stdout with a non-zero exit, matching the real client's convention.
let script = """
#!/bin/sh
printf 'HOME=%s ARGS=%s\\n' "$HOME" "$*" >> "\(callLog.path)"
if [ -n "${FIXTURE_STDOUT:-}" ]; then printf '%s' "$FIXTURE_STDOUT"; fi
if [ -n "${FIXTURE_STDERR:-}" ]; then printf '%s' "$FIXTURE_STDERR" >&2; fi
exit "${FIXTURE_EXIT:-0}"
"""
try? script.write(to: fixtureClient, atomically: true, encoding: .utf8)
try? FileManager.default.setAttributes(
    [.posixPermissions: 0o755], ofItemAtPath: fixtureClient.path
)

let clientHome = fixtureRoot.appendingPathComponent("client-home")
let client = VPNClient(binary: fixtureClient, clientHome: clientHome)

// A successful listing, with the HOME override observable in the call log.
setenv("FIXTURE_STDOUT", #"[{"profile-name": "Alpha"}]"#, 1)
let listed = runBlocking { try await client.listProfiles() }
switch listed {
case .success(let profiles):
    check("the client layer decodes a listing", profiles.first?.name == "Alpha")
case .failure(let error):
    check("the client layer decodes a listing", false)
    print("      \(error)")
}

let log = (try? String(contentsOf: callLog, encoding: .utf8)) ?? ""
// The entire reason this application exists: the child must not inherit the
// real HOME, or the client aborts before doing any work.
check(
    "the child receives the configured HOME, not the caller's",
    log.contains("HOME=\(clientHome.path) ")
)
check("the client home is created on first use", 
    FileManager.default.fileExists(
        atPath: clientHome.appendingPathComponent(".config").path))

// The behavior a stderr-only runner cannot provide.
setenv("FIXTURE_STDOUT", #"{"status": "Error", "message": "Profile not found"}"#, 1)
setenv("FIXTURE_EXIT", "1", 1)
let failed = runBlocking { try await client.listProfiles() }
switch failed {
case .success:
    check("a failing command surfaces the client's own message", false)
case .failure(let error):
    check(
        "a failing command surfaces the client's own message",
        (error as? VPNClient.Failure) == .commandFailed("Profile not found")
    )
}
unsetenv("FIXTURE_EXIT")
unsetenv("FIXTURE_STDOUT")

// A missing binary is reported as such rather than as a failed command.
let absent = VPNClient(
    binary: fixtureRoot.appendingPathComponent("not-here"),
    clientHome: clientHome
)
let missing = runBlocking { try await absent.listProfiles() }
switch missing {
case .success:
    check("a missing client is named as missing", false)
case .failure(let error):
    check(
        "a missing client is named as missing",
        { if case .notInstalled = (error as? VPNClient.Failure) { return true }
          return false }()
    )
}

// The condition that makes the vendor's own interface unusable on this
// machine, converted into a sentence instead of a crash inside the client.
let crookedHome = fixtureRoot.appendingPathComponent("crooked-home")
let elsewhere = fixtureRoot.appendingPathComponent("elsewhere")
try? FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
try? FileManager.default.createDirectory(at: crookedHome, withIntermediateDirectories: true)
try? FileManager.default.createSymbolicLink(
    at: crookedHome.appendingPathComponent(".config"), withDestinationURL: elsewhere
)

let crooked = VPNClient(binary: fixtureClient, clientHome: crookedHome)
let refused = runBlocking { try await crooked.listProfiles() }
switch refused {
case .success:
    check("a symlinked client home is refused", false)
case .failure(let error):
    check(
        "a symlinked client home is refused",
        { if case .homeNotCanonical = (error as? VPNClient.Failure) { return true }
          return false }()
    )
}

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
