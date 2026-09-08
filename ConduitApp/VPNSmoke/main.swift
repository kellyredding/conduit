import Foundation

// Unbuffered, so a check that hangs still shows everything that passed before
// it. Redirected into a pipe by the build, stdout would otherwise be block
// buffered and a hang would surface as total silence — which says nothing
// about where it stopped.
setvbuf(stdout, nil, _IONBF, 0)

// Isolate the settings before anything reads them. Without this the checks
// resolve against whatever is in the real ~/.conduit/config.json and whatever
// CONDUIT_* variables happen to be exported, so an assertion about a compiled
// default passes or fails depending on how the machine is configured that
// afternoon — which is not an assertion about the code at all.
//
// Found the hard way: changing the live sensitivity pattern to try something
// out turned two of these red.
setenv("CONDUIT_ROOT", NSTemporaryDirectory() + "conduit-smoke-root", 1)
setenv("CONDUIT_CONFIG", NSTemporaryDirectory() + "conduit-smoke-absent.json", 1)
for name in [
    "CONDUIT_CLIENT_PATH", "CONDUIT_CLIENT_HOME", "CONDUIT_SENSITIVE_PATTERN",
    "CONDUIT_POLL_ACTIVE", "CONDUIT_POLL_IDLE", "CONDUIT_CONNECT_TIMEOUT",
    "CONDUIT_IDENTITY_HINT_AFTER", "CONDUIT_CONNECT_GRACE_POLLS",
    "CONDUIT_RESTORE_ON_WAKE", "CONDUIT_DAEMON_LOG_DIR",
] {
    unsetenv(name)
}

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
    "restore-on-wake",
    "theme",
    "log-retention-days",
    "log-max-megabytes",
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

// MARK: - Writing settings
//
// Both surfaces write this file, so what writing one setting does to the rest
// of it is a contract rather than an implementation detail.

let writable = NSTemporaryDirectory() + "conduit-smoke-write.json"
setenv("CONDUIT_CONFIG", writable, 1)
try? FileManager.default.removeItem(atPath: writable)

check(
    "a setting round-trips through the file",
    (try? ConduitConfig.set("connect-timeout", to: "45")) != nil
        && ConduitConfig.int("connect-timeout") == 45
)
check(
    "the source is the file once written, not the default",
    ConduitConfig.resolve("connect-timeout")?.source == .file
)
check(
    "writing one setting leaves another alone",
    (try? ConduitConfig.set("poll-interval-idle", to: "90")) != nil
        && ConduitConfig.int("connect-timeout") == 45
        && ConduitConfig.int("poll-interval-idle") == 90
)
check(
    "unsetting falls back to the compiled default",
    (try? ConduitConfig.unset("connect-timeout")) != nil
        && ConduitConfig.int("connect-timeout") == 120
        && ConduitConfig.resolve("connect-timeout")?.source == .default
)
// A file written by a newer build must survive being edited by an older one,
// so a key this build has no idea about is carried through rather than
// quietly dropped.
try? #"{"poll-interval-idle": "90", "future-setting": "keep me"}"#
    .write(toFile: writable, atomically: true, encoding: .utf8)
try? ConduitConfig.set("connect-timeout", to: "30")
let rewritten = (try? String(contentsOfFile: writable, encoding: .utf8)) ?? ""
check("an unrecognized setting survives a write", rewritten.contains("future-setting"))
check("and the written file ends in a newline", rewritten.hasSuffix("\n"))
// The file's own invariant: it records what differs from a default and
// nothing else. Writing a default back into it freezes today's answer, and
// invisibly, because the value on screen reads the same either way.
try? FileManager.default.removeItem(atPath: writable)
try? ConduitConfig.apply("connect-timeout", "45")
check(
    "applying a non-default records it",
    ConduitConfig.resolve("connect-timeout")?.source == .file
)
try? ConduitConfig.apply("connect-timeout", "120")
check(
    "applying the default removes it instead of writing it",
    ConduitConfig.resolve("connect-timeout")?.source == .default
)
try? ConduitConfig.apply("connect-timeout", "45")
try? ConduitConfig.apply("connect-timeout", "   ")
check(
    "an emptied value means the default too",
    ConduitConfig.resolve("connect-timeout")?.source == .default
)
try? ConduitConfig.apply("poll-interval-idle", "90")
try? ConduitConfig.apply("poll-interval-idle", "60")
check(
    "a file with nothing left to record is removed, not left empty",
    !FileManager.default.fileExists(atPath: writable)
)

try? ConduitConfig.set("connect-timeout", to: "45")
try? ConduitConfig.set("poll-interval-idle", to: "90")
try? ConduitConfig.resetAll()
check(
    "resetting everything returns every setting to its default",
    ConduitConfig.keys.allSatisfy {
        ConduitConfig.resolve($0.name)?.source == .default
    }
)
check(
    "resetting with nothing to reset is not an error",
    (try? ConduitConfig.resetAll()) != nil
)

check(
    "a setting that does not exist is refused rather than written",
    (try? ConduitConfig.set("not-a-setting", to: "x")) == nil
)

// Back to the absent file the rest of the checks expect.
setenv("CONDUIT_CONFIG", NSTemporaryDirectory() + "conduit-smoke-absent.json", 1)
try? FileManager.default.removeItem(atPath: writable)

// MARK: - Settings window coverage
//
// The window generates its fields, but which card a setting belongs to is a
// human judgement, so a new setting can be added and never assigned a home.
// The failure is silent and narrow: the setting exists, both surfaces read it,
// and only the window cannot see it.

check(
    "every setting is owned by exactly one tab",
    SettingsTab.ownedKeys.sorted() == ConduitConfig.keys.map(\.name).sorted()
)
check(
    "no setting is claimed by two tabs",
    Set(SettingsTab.ownedKeys).count == SettingsTab.ownedKeys.count
)
check(
    "every tab has at least one setting to show",
    SettingsTab.allCases.allSatisfy { !$0.keys.isEmpty }
)

// MARK: - Sensitivity

check("the default pattern matches a production-ish name", Sensitivity.isSensitive("Prod-Alpha"))
check("the default pattern ignores other names", !Sensitivity.isSensitive("Alpha"))
check("a broken pattern is distinguishable from an empty one", !Sensitivity.patternIsBroken())

// MARK: - Menu icon reduction

func state(
    _ name: String,
    _ status: VPNStatus?,
    sensitive: Bool = false,
    movedSecondsAgo: TimeInterval? = nil
) -> ProfileState {
    let stamp = movedSecondsAgo.map { ago -> String in
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date().addingTimeInterval(-ago))
    }
    return ProfileState(
        name: name,
        status: status,
        rawStatus: status?.rawValue ?? "Unknown",
        updatedAt: stamp,
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
// The bar deliberately says nothing about sensitivity: no glyph tested could
// carry it at that size. A live tunnel reads as live whether or not connecting
// to it warranted a second thought, and the panel marks the row instead.
check(
    "a sensitive tunnel reads in the bar exactly like any other",
    MenuIcon.state(
        for: [state("Prod", .connected, sensitive: true)],
        health: .ready
    ) == .connected
)
check(
    "the rule still exists, and still has a mark for the panel",
    !Sensitivity.markSymbolName.isEmpty && Sensitivity.isSensitive("Prod-Alpha")
)
check(
    "something settling outranks a live tunnel",
    MenuIcon.state(
        for: [state("Prod", .connected, sensitive: true)],
        health: .ready,
        settling: true
    ) == .connecting
)
check(
    "nothing settling lets the live tunnel read through",
    MenuIcon.state(
        for: [state("Prod", .connected, sensitive: true), state("Alpha", .connecting)],
        health: .ready,
        settling: false
    ) == .connected
)

// MARK: - Live transition vs abandoned one
//
// The distinction the bar rests on. Both are transitional statuses and nothing
// in a status response separates them except how long the state has sat, so
// these two checks are the whole of what keeps the bar from either lying for
// ten minutes or going silent during a nine-second connect.

let window: TimeInterval = 120

check(
    "a transition that just moved is settling",
    state("Alpha", .waitingForIdentity, movedSecondsAgo: 3).isSettling(within: window)
)
check(
    "one still moving well inside a connect's duration is settling",
    state("Alpha", .connecting, movedSecondsAgo: 18).isSettling(within: window)
)
// Measured: an abandoned attempt held WaitingForIdentity for 598 seconds with
// its timestamp frozen at the moment it entered, while a real connect runs
// 9-18 seconds end to end. The bound separates two populations 30x apart.
check(
    "an abandoned attempt is not settling",
    !state("Alpha", .waitingForIdentity, movedSecondsAgo: 598).isSettling(within: window)
)
check(
    "a resting profile is never settling, however fresh",
    !state("Alpha", .connected, movedSecondsAgo: 1).isSettling(within: window)
)
check(
    "an unreadable timestamp reads as settling rather than as nothing happening",
    state("Alpha", .connecting).isSettling(within: window)
)

// MARK: - The restore decision
//
// Every defect this has had was in the ordering of its rules, and none were
// reachable from a check while the decision sat inside a service wired to a
// workspace notification, a path monitor and a subprocess. These stand the
// rules up on their own.

func decide(
    attempts: Int,
    armedSecondsAgo: TimeInterval? = 0,
    wanted: Set<String>,
    profiles: [ProfileState]
) -> RestoreDecision {
    RestoreDecision.evaluate(
        attempts: attempts,
        maxAttempts: 4,
        armedAt: armedSecondsAgo.map { Date().addingTimeInterval(-$0) },
        armWindow: 120,
        wanted: wanted,
        profiles: profiles,
        settleWindow: window
    )
}

// The window this was written for. `isSettling` is false for a profile that has
// arrived, so between arrival and the next poll the arming was live and
// unguarded — and arriving is itself what raises the path event that lands
// there. A second attempt then disconnected the tunnel the first one built.
check(
    "an arrived profile disarms the restore instead of earning another attempt",
    decide(
        attempts: 1,
        wanted: ["Alpha"],
        profiles: [state("Alpha", .connected, movedSecondsAgo: 1)]
    ) == RestoreDecision(action: .disarm(.confirmed), wanted: [])
)
// The counterpart, and the regression that must not come back with it: before
// any attempt has run, a Connected reading describes the network the machine
// had before it slept. Consulted 52 ms after arming, it confirmed a restore
// that had not happened and stood the whole thing down.
check(
    "an arrived profile is not trusted before the first attempt",
    decide(
        attempts: 0,
        wanted: ["Alpha"],
        profiles: [state("Alpha", .connected, movedSecondsAgo: 1)]
    ).action == .act
)
check(
    "a moving attempt is held rather than interrupted",
    decide(
        attempts: 1,
        wanted: ["Alpha"],
        profiles: [state("Alpha", .connecting, movedSecondsAgo: 3)]
    ).action == .hold(.settling)
)
// The retry has to stay reachable: an abandoned attempt is transitional for ten
// minutes, and testing that instead of whether it is still moving would decline
// every retry for the whole timeout.
check(
    "an abandoned attempt does not hold the restore for the whole timeout",
    decide(
        attempts: 1,
        wanted: ["Alpha"],
        profiles: [state("Alpha", .waitingForIdentity, movedSecondsAgo: 598)]
    ).action == .act
)
// An arming whose wake never produced a satisfied path event otherwise stays
// armed forever: the poll's clearing requires a completed attempt and there has
// not been one. The events that finally arrive are a person's own connect.
check(
    "an arming that never fired expires instead of waiting for a later event",
    decide(
        attempts: 0,
        armedSecondsAgo: 121,
        wanted: ["Alpha"],
        profiles: [state("Alpha", .notConnected)]
    ).action == .disarm(.expired)
)
check(
    "an arming still inside the window acts",
    decide(
        attempts: 0,
        armedSecondsAgo: 119,
        wanted: ["Alpha"],
        profiles: [state("Alpha", .notConnected)]
    ).action == .act
)
// Expiry outranks settling on purpose. A stale arming sitting beside a connect
// the person is making themselves has to be given up, not held for the event
// after — holding it is how it reaches their tunnel.
check(
    "a stale arming expires even while something is moving",
    decide(
        attempts: 0,
        armedSecondsAgo: 300,
        wanted: ["Alpha"],
        profiles: [state("Alpha", .connecting, movedSecondsAgo: 2)]
    ).action == .disarm(.expired)
)
check(
    "the attempt cap is still the last word",
    decide(
        attempts: 4,
        wanted: ["Alpha"],
        profiles: [state("Alpha", .notConnected)]
    ).action == .disarm(.exhausted)
)
// Confirming one does not abandon the other.
check(
    "one of two confirmed leaves the other wanted",
    decide(
        attempts: 1,
        wanted: ["Alpha", "Bravo"],
        profiles: [state("Alpha", .connected), state("Bravo", .notConnected)]
    ) == RestoreDecision(action: .act, wanted: ["Bravo"])
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

// MARK: - Log housekeeping
//
// The only thing in this application that deletes a file, so the checks are
// about what it leaves alone as much as what it removes.

let logHome = fixtureRoot.appendingPathComponent("log-home")
let logDir = ClientLogs.directory(clientHome: logHome)
try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

func writeLog(_ name: String, daysOld: Int) {
    let url = logDir.appendingPathComponent(name)
    FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
    let when = Date().addingTimeInterval(-Double(daysOld) * 86_400)
    try? FileManager.default.setAttributes([.modificationDate: when], ofItemAtPath: url.path)
}

writeLog("aws_vpn_client_cli_20260101.log", daysOld: 30)
writeLog("aws_vpn_client_cli_20260210.log", daysOld: 10)
writeLog("aws_vpn_client_cli_20260811.log", daysOld: 0)
writeLog("something-else.txt", daysOld: 30)
writeLog("notes.log", daysOld: 30)

let removed = ClientLogs.prune(clientHome: logHome, retainingDays: 3)
check("old client logs are removed", removed == 2)
check(
    "today's log survives",
    FileManager.default.fileExists(
        atPath: logDir.appendingPathComponent("aws_vpn_client_cli_20260811.log").path)
)
// This runs unattended at every launch. A loop that trusts its directory
// rather than the file name is one misconfigured path from being a problem.
check(
    "a file that is not a client log is left alone even when old",
    FileManager.default.fileExists(
        atPath: logDir.appendingPathComponent("something-else.txt").path)
        && FileManager.default.fileExists(
            atPath: logDir.appendingPathComponent("notes.log").path)
)
check("pruning again removes nothing", ClientLogs.prune(clientHome: logHome, retainingDays: 3) == 0)
check(
    "a missing log directory is not an error",
    ClientLogs.prune(
        clientHome: fixtureRoot.appendingPathComponent("no-such-home"),
        retainingDays: 3
    ) == 0
)
check("footprint counts only client logs", ClientLogs.footprint(clientHome: logHome) == 1)
check(
    "zero retention still keeps today's",
    {
        _ = ClientLogs.prune(clientHome: logHome, retainingDays: 0)
        return FileManager.default.fileExists(
            atPath: logDir.appendingPathComponent("aws_vpn_client_cli_20260811.log").path)
    }()
)

// Retention removes whole days; it cannot bound a single day that goes chatty.
// These check the backstop that does not care why.

let capHome = fixtureRoot.appendingPathComponent("cap-home")
let capDir = ClientLogs.directory(clientHome: capHome)
try? FileManager.default.createDirectory(at: capDir, withIntermediateDirectories: true)

func writeSized(_ name: String, kb: Int, daysOld: Int) {
    let url = capDir.appendingPathComponent(name)
    FileManager.default.createFile(
        atPath: url.path, contents: Data(count: kb * 1024))
    let when = Date().addingTimeInterval(-Double(daysOld) * 86_400)
    try? FileManager.default.setAttributes(
        [.modificationDate: when], ofItemAtPath: url.path)
}

writeSized("aws_vpn_client_cli_20260808.log", kb: 400, daysOld: 3)
writeSized("aws_vpn_client_cli_20260809.log", kb: 400, daysOld: 2)
writeSized("aws_vpn_client_cli_20260810.log", kb: 400, daysOld: 1)
writeSized("aws_vpn_client_cli_20260811.log", kb: 400, daysOld: 0)

// 1600 KB total, capped at 1 MB: the two oldest go, the newest survives.
let capped = ClientLogs.enforceCap(clientHome: capHome, maxBytes: 1_048_576)
check("the cap removes files until the total fits", capped == 2)
check(
    "the oldest go first",
    !FileManager.default.fileExists(
        atPath: capDir.appendingPathComponent("aws_vpn_client_cli_20260808.log").path)
        && FileManager.default.fileExists(
            atPath: capDir.appendingPathComponent("aws_vpn_client_cli_20260811.log").path)
)
check(
    "and it actually got under the ceiling",
    ClientLogs.footprint(clientHome: capHome) <= 1_048_576
)
check(
    "a directory already under the ceiling is left alone",
    ClientLogs.enforceCap(clientHome: capHome, maxBytes: 10_485_760) == 0
)

// The case retention cannot reach: one day, too big on its own.
let hogHome = fixtureRoot.appendingPathComponent("hog-home")
let hogDir = ClientLogs.directory(clientHome: hogHome)
try? FileManager.default.createDirectory(at: hogDir, withIntermediateDirectories: true)
let hog = hogDir.appendingPathComponent("aws_vpn_client_cli_20260811.log")
FileManager.default.createFile(atPath: hog.path, contents: Data(count: 2 * 1024 * 1024))
check(
    "retention will not touch a single oversized current day",
    ClientLogs.prune(clientHome: hogHome, retainingDays: 3) == 0
)
check(
    "the cap will — nothing holds these open, so it is recreated",
    ClientLogs.enforceCap(clientHome: hogHome, maxBytes: 1_048_576) == 1
)
check(
    "a cap of zero is treated as no cap rather than as delete everything",
    {
        FileManager.default.createFile(atPath: hog.path, contents: Data(count: 1024))
        return ClientLogs.enforceCap(clientHome: hogHome, maxBytes: 0) == 0
    }()
)

// MARK: - Attempt watcher
//
// The whole reason this type exists is that the client's own exit code lies
// about connection state, so every check here drives it against a scripted
// sequence of readings rather than against a real client. Time is driven too:
// a watcher that took real seconds to check would make the timeout case cost
// two minutes, and nobody runs a gate that does that.

/// Advances only when the watcher sleeps, so a two-minute timeout costs
/// nothing and the same code path runs identically here and in the app.
final class TestClock: AttemptClock, @unchecked Sendable {
    private var elapsed: TimeInterval = 0
    func now() -> TimeInterval { elapsed }
    func sleep(_ seconds: TimeInterval) async { elapsed += seconds }
}

/// Yields the scripted readings in order, then repeats the last one forever —
/// so a sequence that never reaches a terminal state models a client that has
/// stopped making progress rather than one that ran out of answers.
final class ScriptedProbe: @unchecked Sendable {
    private let readings: [VPNStatus?]
    private var index = 0
    init(_ readings: [VPNStatus?]) { self.readings = readings }
    func next() -> VPNStatus? {
        defer { index += 1 }
        return readings[min(index, readings.count - 1)]
    }
}

/// Runs an async body from ordinary top-level code.
///
/// Keeps every top-level binding in this file a plain synchronous one. A single
/// top-level `await` would turn all of them into async global initializers,
/// which is a large change in how this file executes to buy nothing a checking
/// tool needs. Blocking here is safe because the work is detached: it runs on
/// the concurrency pool rather than on the thread waiting for it.
///
/// Whether top-level `await` would also have worked is untested — the run that
/// suggested otherwise turned out to be a stale binary, because `make build`
/// builds only the application scheme and this tool is built by `make smoke`.
final class ResultBox<T>: @unchecked Sendable { var value: T? }

func runAsync<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = ResultBox<T>()
    Task.detached {
        box.value = await body()
        semaphore.signal()
    }
    semaphore.wait()
    return box.value!
}

final class EventLog: @unchecked Sendable {
    private(set) var events: [AttemptEvent] = []
    func record(_ event: AttemptEvent) { events.append(event) }
    var hints: Int { events.filter { $0 == .identityHint }.count }
    var observations: Int {
        events.filter { if case .observed = $0 { return true } else { return false } }
            .count
    }
}

func watchConnect(
    _ readings: [VPNStatus?],
    timeout: TimeInterval = 120,
    hintAfter: TimeInterval = 5,
    interval: TimeInterval = 2,
    gracePolls: Int = 3
) -> (AttemptOutcome, EventLog) {
    let probe = ScriptedProbe(readings)
    let log = EventLog()
    let watcher = AttemptWatcher(probe: { probe.next() }, clock: TestClock())
    let outcome = runAsync {
        await watcher.watchConnect(
            timeout: timeout,
            hintAfter: hintAfter,
            interval: interval,
            gracePolls: gracePolls
        ) { log.record($0) }
    }
    return (outcome, log)
}

let (reached, _) = watchConnect([.connecting, .waitingForIdentity, .connected])
check("a connect that completes reads as connected", reached == .connected)

// The asymmetry that makes this type necessary: NotConnected means both "idle"
// and "what you just asked for failed", and only observed progress separates
// them.
let (afterProgress, _) = watchConnect([.connecting, .notConnected])
check("dropping back to idle after progress is a failure", afterProgress == .failed)

let (slowStart, _) = watchConnect(
    [.notConnected, .notConnected, .connecting, .connected], gracePolls: 3
)
check(
    "idle readings before any progress are tolerated, not failed",
    slowStart == .connected
)
let (neverStarted, _) = watchConnect(
    [.notConnected, .notConnected, .notConnected], gracePolls: 3
)
check("idle readings past the grace count are a failure", neverStarted == .failed)

// A timeout must not share an outcome with a failure. Sign-in happens in a
// browser, so giving up watching says nothing about whether the attempt will
// eventually succeed, and anything treating them alike reports a loss on
// something still in progress.
let (gaveUp, _) = watchConnect([.connecting], timeout: 10, interval: 2)
check("a watch that runs out of time is not a failure", gaveUp == .timedOut)
check("and a timeout is distinguishable from one", !AttemptOutcome.timedOut.isFailure)

let (_, hintLog) = watchConnect(
    [.waitingForIdentity, .waitingForIdentity, .waitingForIdentity,
     .waitingForIdentity, .waitingForIdentity, .connected],
    hintAfter: 5, interval: 2
)
check("waiting on sign-in eventually says so", hintLog.hints == 1)
check("and says it once, not once per poll", hintLog.hints < 2)

let (_, quietLog) = watchConnect([.connecting, .connecting, .connecting, .connected])
check(
    "a status is reported when it changes, not when it is polled",
    quietLog.observations == 2
)

// A client release that adds a state has not thereby broken the connection,
// so an unrecognized reading counts as motion.
let (unrecognized, _) = watchConnect([nil, nil, .connected], gracePolls: 3)
check("an unrecognized status is motion rather than failure", unrecognized == .connected)
let (unrecognizedThenIdle, _) = watchConnect([nil, .notConnected], gracePolls: 3)
check(
    "and having seen one, idle means the attempt failed",
    unrecognizedThenIdle == .failed
)

let teardown = ScriptedProbe([.connected, .disconnecting, .notConnected])
let teardownWatcher = AttemptWatcher(probe: { teardown.next() }, clock: TestClock())
let torndown = runAsync {
    await teardownWatcher.watchDisconnect(timeout: 30, interval: 2) { _ in }
}
check("a teardown that reaches idle reads as disconnected", torndown == .disconnected)

let stuck = ScriptedProbe([.connected])
let stuckWatcher = AttemptWatcher(probe: { stuck.next() }, clock: TestClock())
let neverWent = runAsync {
    await stuckWatcher.watchDisconnect(timeout: 10, interval: 2) { _ in }
}
check("a teardown that never lands times out", neverWent == .timedOut)

// MARK: - Throughput, differenced from cumulative totals
//
// The client reports totals only, so every rate here is the quotient of two
// readings, and the interesting cases are the ones that must NOT produce a
// number: the first reading, a counter that reset, a gap nobody was watching
// through, and a reading that never arrived. Each of those has an arithmetically
// valid answer that describes something untrue.

func counters(in inbound: Int64, out outbound: Int64) -> VPNByteCounters {
    VPNByteCounters(
        tunnelIn: inbound,
        tunnelOut: outbound,
        transportIn: inbound,
        transportOut: outbound
    )
}

let start = Date(timeIntervalSince1970: 1_000_000)
let stale: TimeInterval = 10

var series = ThroughputSeries()
series.record(counters(in: 1_000, out: 500), at: start, staleAfter: stale)
check("one reading is not a rate", series.isEmpty)

series.record(
    counters(in: 3_000, out: 1_500),
    at: start.addingTimeInterval(2),
    staleAfter: stale
)
check("two readings make one rate", series.rates.count == 1)
check("inbound rate is the difference over the interval", series.latest?.inPerSecond == 1_000)
check("outbound rate likewise", series.latest?.outPerSecond == 500)
check("the first rate of a run says so", series.latest?.startsRun == true)

series.record(
    counters(in: 5_000, out: 2_500),
    at: start.addingTimeInterval(4),
    staleAfter: stale
)
check("a contiguous rate does not start a run", series.latest?.startsRun == false)
check("and the peak is the largest seen", series.peak == 1_000)

// A counter that went backwards is a new attempt, not negative traffic.
var afterReset = series
afterReset.record(
    counters(in: 10, out: 5),
    at: start.addingTimeInterval(6),
    staleAfter: stale
)
check("a counter that reset yields no rate", afterReset.rates.count == 2)
afterReset.record(
    counters(in: 2_010, out: 1_005),
    at: start.addingTimeInterval(8),
    staleAfter: stale
)
check(
    "and the reading that reset becomes the new baseline",
    afterReset.rates.count == 3 && afterReset.latest?.inPerSecond == 1_000
)
check("a rate after a reset begins a new run", afterReset.latest?.startsRun == true)

// A gap longer than the cadence allows: the counters kept climbing while nobody
// was looking, and spreading that traffic over the gap reports the mean of an
// unobserved period as the current rate.
var afterGap = series
afterGap.record(
    counters(in: 500_000, out: 250_000),
    at: start.addingTimeInterval(4 + stale + 1),
    staleAfter: stale
)
check("a gap past the stale limit yields no rate", afterGap.rates.count == 2)

// An absent payload is a hole, not a quiet moment. `details` arrives
// present-with-zeros from a stalled attempt, so absence cannot be read as zero.
var withHole = series
withHole.record(nil, at: start.addingTimeInterval(6), staleAfter: stale)
check("an absent reading yields no rate", withHole.rates.count == 2)
withHole.record(
    counters(in: 7_000, out: 3_500),
    at: start.addingTimeInterval(8),
    staleAfter: stale
)
check(
    "and the reading after a hole is not differenced across it",
    withHole.rates.count == 2
)
withHole.record(
    counters(in: 9_000, out: 4_500),
    at: start.addingTimeInterval(10),
    staleAfter: stale
)
check("while the interval after that is measured", withHole.rates.count == 3)
check("and it begins a new run", withHole.latest?.startsRun == true)

// Two readings in one instant divide by zero; a clock that moved backwards
// divides by a negative.
var sameInstant = ThroughputSeries()
sameInstant.record(counters(in: 1_000, out: 500), at: start, staleAfter: stale)
sameInstant.record(counters(in: 2_000, out: 1_000), at: start, staleAfter: stale)
check("two readings at one instant yield no rate", sameInstant.isEmpty)

var backwards = ThroughputSeries()
backwards.record(counters(in: 1_000, out: 500), at: start, staleAfter: stale)
backwards.record(
    counters(in: 2_000, out: 1_000),
    at: start.addingTimeInterval(-5),
    staleAfter: stale
)
check("a clock that moved backwards yields no rate", backwards.isEmpty)

var bounded = ThroughputSeries(capacity: 3)
for step in 1...10 {
    bounded.record(
        counters(in: Int64(step) * 1_000, out: Int64(step) * 100),
        at: start.addingTimeInterval(Double(step)),
        staleAfter: stale
    )
}
check("history is bounded", bounded.rates.count == 3)
check("and keeps the newest", bounded.latest?.at == start.addingTimeInterval(10))

// A cadence slower than a fixed staleness limit would discard every sample. The
// limit is derived from the interval for exactly this reason, so a rate recorded
// at a slow cadence still counts when the limit travels with it.
var slowCadence = ThroughputSeries()
slowCadence.record(counters(in: 0, out: 0), at: start, staleAfter: 300)
slowCadence.record(
    counters(in: 6_000, out: 600),
    at: start.addingTimeInterval(60),
    staleAfter: 300
)
check("a slow cadence still measures", slowCadence.latest?.inPerSecond == 100)

// MARK: - Routes and resolvers, as the OS prints them
//
// The fixtures below carry no addresses at all — not even documentation ranges.
// The disclosure audit refuses a dotted quad anywhere in a tracked file, which is
// the right rule for a public repository driving a VPN, and these parsers happen
// to make it costless: they *locate* the destination, gateway, and nameserver
// fields and never interpret them, so an opaque token exercises the same code
// path an address would.
//
// What that leaves untested is the live shape — real output with a tunnel up.
// Nothing was connected when these were written, so the utun filtering is
// verified against the format above and against the format alone. It needs one
// pass with a tunnel established before it can be called measured.

let routeTable = """
    Routing tables

    Internet:
    Destination        Gateway            Flags        Netif Expire
    default            gateway-a          UGScg          en0
    link-local         link#24            UCSIg     bridge100      !
    dest-one           gateway-b          UGSc         utun4
    dest-two           utun4              UHWIig       utun4
    dest-three         gateway-c          UGSc         utun7
    utun9              gateway-d          UH             lo0
    """

let tunnelRoutes = TunnelFactsParser.routes(fromNetstat: routeTable)
check("only tunnel rows are taken", tunnelRoutes.count == 3)
check(
    "the header and other interfaces fall out without being parsed",
    !tunnelRoutes.contains { $0.interface == "en0" || $0.interface == "bridge100" }
)
check("destination comes from the first field", tunnelRoutes.first?.destination == "dest-one")
check("gateway from the second", tunnelRoutes.first?.gateway == "gateway-b")

// The gateway column can hold an interface name on a point-to-point route, so
// the interface is the LAST matching field. Taking the first would report the
// gateway as the interface for this row.
let pointToPoint = tunnelRoutes.first { $0.destination == "dest-two" }
check("a route whose gateway is the interface still reads correctly", pointToPoint?.interface == "utun4")
check("and keeps its gateway", pointToPoint?.gateway == "utun4")

// A tunnel name in the destination column is not a tunnel route. Guards the one
// column assumption the parser does make.
check(
    "a row merely mentioning a tunnel elsewhere is not a tunnel route",
    !tunnelRoutes.contains { $0.destination == "utun9" }
)

let facts = TunnelFacts(routes: tunnelRoutes, resolvers: [], readAt: start)
check("interfaces are listed once, in first-seen order", facts.interfaces == ["utun4", "utun7"])
check("routes filter by interface", facts.routes(on: "utun7").count == 1)
check("having read and found nothing is not the same as not having read", facts.hasBeenRead)
check("and an unread set says so", !TunnelFacts().hasBeenRead)

// Split versus full is the difference between "all traffic goes through the VPN"
// and "four prefixes do", and it decides what every byte counter in the window
// means. Measured on a live tunnel: `default` belonged to the physical interface,
// so a speed test crossed the tunnel not at all.
check("a tunnel holding only specific prefixes is a split tunnel", !facts.carriesDefaultRoute)

let fullTunnel = TunnelFactsParser.routes(
    fromNetstat: """
        Destination        Gateway            Flags        Netif Expire
        default            gateway-a          UGScg          en0
        default            gateway-b          UGSc         utun4
        dest-one           gateway-b          UGSc         utun4
        """
)
check(
    "a default route on a tunnel is a full tunnel",
    TunnelFacts(routes: fullTunnel, resolvers: [], readAt: start).carriesDefaultRoute
)
check(
    "and the physical interface's own default is not mistaken for one",
    !fullTunnel.contains { $0.interface == "en0" }
)

// Two sections, and the resolver numbering restarts in the second — measured.
let dnsConfiguration = """
    DNS configuration

    resolver #1
      search domain[0] : example.test
      nameserver[0] : ns-wired
      if_index : 14 (en0)
      flags    : Request A records
      reach    : 0x00000002 (Reachable)

    resolver #2
      domain   : example.test
      options  : mdns
      timeout  : 5
      flags    : Request A records
      order    : 300000

    resolver #3
      nameserver[0] : ns-unscoped
      flags    : Request A records

    DNS configuration (for scoped queries)

    resolver #1
      search domain[0] : example.test
      search domain[1] : sub.example.test
      nameserver[0] : ns-tunnel-first
      nameserver[1] : ns-tunnel-second
      if_index : 21 (utun4)
      flags    : Scoped, Request A records
      reach    : 0x00000002 (Reachable)

    resolver #2
      nameserver[0] : ns-wired
      if_index : 14 (en0)
      flags    : Scoped, Request A records
    """

// Every resolver with a nameserver is kept, scoped or not. On the deployment
// this was measured against, nothing is scoped to the tunnel — so a list filtered
// to tunnel-scoped resolvers was empty by construction and answered a narrower
// question than "what will resolve names here".
let allResolvers = TunnelFactsParser.resolvers(fromScutil: dnsConfiguration)
check("every resolver offering a nameserver is kept", allResolvers.count == 4)
check(
    "a block with no nameserver is not a resolver worth listing",
    !allResolvers.contains { $0.nameservers.isEmpty }
)
check(
    "order is preserved as the OS reports it",
    allResolvers.map(\.interface) == ["en0", nil, "utun4", "en0"]
)

let tunnelScoped = allResolvers.filter(\.isTunnelScoped)
check("a tunnel-scoped resolver is recognized as one", tunnelScoped.count == 1)
check("the interface comes from if_index", tunnelScoped.first?.interface == "utun4")
check(
    "nameservers keep the order they are used in",
    tunnelScoped.first?.nameservers.map(\.address)
        == ["ns-tunnel-first", "ns-tunnel-second"]
)
check(
    "a freshly parsed nameserver claims no path until one is looked up",
    tunnelScoped.first?.nameservers.allSatisfy { $0.reachedThrough == nil } == true
)
check(
    "and an unknown path is not a tunnel path",
    tunnelScoped.first?.nameservers.allSatisfy { !$0.isReachedThroughTunnel } == true
)
check(
    "search domains are collected",
    tunnelScoped.first?.searchDomains == ["example.test", "sub.example.test"]
)

let unscoped = allResolvers.first { $0.interface == nil }
check("a resolver naming no interface is unscoped rather than dropped", unscoped != nil)
check("and says so rather than showing a blank", unscoped?.scopeDescription == "not scoped to an interface")
check("an unscoped resolver is not claimed for the tunnel", unscoped?.isTunnelScoped == false)
check(
    "nor is one scoped to the physical interface",
    allResolvers.first?.isTunnelScoped == false
)

// The same resolver is routinely printed in both sections. Listing it twice
// would claim two resolvers exist.
let duplicated = """
    DNS configuration

    resolver #1
      nameserver[0] : ns-tunnel
      if_index : 21 (utun4)

    DNS configuration (for scoped queries)

    resolver #1
      nameserver[0] : ns-tunnel
      if_index : 21 (utun4)
    """
check(
    "an identical resolver in both sections is one resolver",
    TunnelFactsParser.resolvers(fromScutil: duplicated).count == 1
)

// MARK: - Which interface reaches an address
//
// The kernel is asked rather than the routing table re-implemented. Computing it
// here would need the longest matching prefix across every interface, so a
// comparison against tunnel routes alone would claim the tunnel for an address a
// more specific route elsewhere actually owns — and it would rest on an inference
// about what an abbreviated destination means.
//
// It also makes this testable at all: only the interface line is read, so the
// fixture needs no address, and the disclosure audit stays untouched.

let routeToTunnel = """
       route to: <an address>
    destination: dest-one
           mask: a-mask
        gateway: gateway-b
      interface: utun4
          flags: <UP,GATEWAY,DONE,STATIC,PRCLONING,GLOBAL>
     recvpipe  sendpipe  ssthresh  rtt,msec    rttvar  hopcount      mtu     expire
            0         0         0         0         0         0      1500         0
    """
check(
    "the interface is taken from the line that names it",
    TunnelFactsParser.interfaceName(fromRouteGet: routeToTunnel) == "utun4"
)
check(
    "and a tunnel path is recognized as one",
    Nameserver(address: "ns-tunnel", reachedThrough: "utun4").isReachedThroughTunnel
)
check(
    "while the physical interface is not",
    !Nameserver(address: "ns-wired", reachedThrough: "en0").isReachedThroughTunnel
)

// An address the kernel will not route produces output with no interface line.
// Reading that as the default route would be the confident wrong answer this
// whole approach exists to avoid.
check(
    "output with no interface line yields no path",
    TunnelFactsParser.interfaceName(
        fromRouteGet: "   route to: <an address>\n"
            + "route: writing to routing socket: not in table\n"
    ) == nil
)
check(
    "and neither does empty output",
    TunnelFactsParser.interfaceName(fromRouteGet: "") == nil
)

check(
    "if_index yields the name in parentheses",
    TunnelFactsParser.interfaceName(fromIfIndex: "21 (utun4)") == "utun4"
)
check(
    "and nothing when there is no name to take",
    TunnelFactsParser.interfaceName(fromIfIndex: "21") == nil
)
check("a tunnel is recognized by name", TunnelFactsParser.isTunnel("utun4"))
check("and other interfaces are not", !TunnelFactsParser.isTunnel("en0"))
check("neither is empty output", TunnelFactsParser.routes(fromNetstat: "").isEmpty)
check("nor empty resolver output", TunnelFactsParser.resolvers(fromScutil: "").isEmpty)

// MARK: - Activity log

var activityLog = ActivityLog(capacity: 3)
activityLog.record(.connected, profile: "Alpha", at: start)
activityLog.record(.disconnected, profile: "Alpha", at: start.addingTimeInterval(60))
check("the newest entry is first", activityLog.entries.first?.kind == .disconnected)
check("and carries its profile", activityLog.entries.first?.profile == "Alpha")
check("entries read as observation", activityLog.entries.first?.text == "Alpha disconnected")

activityLog.record(.clientUnavailable, at: start.addingTimeInterval(120))
activityLog.record(.clientReady, at: start.addingTimeInterval(180))
check("the log is bounded", activityLog.entries.count == 3)
check("and the oldest is what goes", !activityLog.entries.contains { $0.kind == .connected })
check(
    "the client's own availability is recorded without a profile",
    activityLog.entries.first?.profile == nil
        && activityLog.entries.first?.text == "The client answered again"
)
check("an empty log says so", ActivityLog().isEmpty)

// A tunnel that predates the process produced no transition to observe. Recorded
// as a state that was found, worded so it cannot be mistaken for one that was
// witnessed.
var baseline = ActivityLog()
baseline.record(.alreadyConnected, profile: "Bravo", at: start)
check(
    "a connection that predates the process is recorded as found, not witnessed",
    baseline.entries.first?.text == "Bravo was already connected"
)
check(
    "and it is a distinct kind rather than an ordinary connect",
    baseline.entries.first?.kind == .alreadyConnected
)

// MARK: - Why the client last ended a session
//
// The one place the model layer reports a cause instead of an observation. It
// is allowed to because the daemon writes the cause down in words, so reading
// it is measurement — but that only holds if the reading is exact, and the two
// negative checks below are the ones that matter most. A parser that announced
// a failure on every healthy connect would be worse than having none.
//
// Fixture profile names are invented and no fixture carries an address. The
// parser locates fields without interpreting them, so an empty bracket
// exercises the same path a real subnet would.

func readTeardown(_ log: String) -> DaemonTeardown? {
    DaemonTeardownParser.latest(fromDaemonLog: log)
}

let localNetLog = """
    2026-01-02T03:04:05.100000Z  INFO tokio-rt-worker ThreadId(13) LocalNet: new subnets detected new_cidrs=[]
    2026-01-02T03:04:05.200000Z  INFO tokio-rt-worker ThreadId(13) LocalNet: new LAN detected, stopping session
    2026-01-02T03:04:06.000000Z  INFO ThreadId(99) connection: ConnectionStatus state transition old_state=Reconnecting new_state=WaitingForIdentity connection_id=1 profile=Alpha
    """

check(
    "a local network change is read as the cause",
    readTeardown(localNetLog)?.cause == .localNetworkChanged
)
// The line that names this cause comes from the network watcher and carries no
// profile of its own, so the name has to come from a neighbour.
check(
    "and the profile comes from the line below it, having none of its own",
    readTeardown(localNetLog)?.profile == "Alpha"
)
// Reported as the consequence rather than the cause. A reader told only that a
// sign-in is needed fixes the wrong thing, repeatedly, because it comes back.
check(
    "and the sign-in it caused is reported as still needed",
    readTeardown(localNetLog)?.needsSignIn == true
)
check(
    "and the time is the initiating event's, not the sign-in's",
    readTeardown(localNetLog).map {
        ISO8601DateFormatter().string(from: $0.at).hasPrefix("2026-01-02T03:04:05")
    } == true
)

// The subtlety the parser turns on. A federated sign-in *begins* with an
// AUTH_FAILED and a challenge — observed on a connect that went on to work
// perfectly two seconds later. What separates that from a real failure is the
// state the transition came from, not the words in it.
let normalSignIn = """
    2026-01-02T03:04:05.000000Z  INFO ThreadId(99) connection: OpenVPN callback Log(OvpnLog { text: "AUTH_FAILED\\n" }) profile=Alpha
    2026-01-02T03:04:05.100000Z  INFO ThreadId(99) connection: OpenVPN callback Event(OvpnEvent { error: true, fatal: true, name: "DYNAMIC_CHALLENGE", info: "CRV1:R:opaque" }) profile=Alpha
    2026-01-02T03:04:05.200000Z  INFO ThreadId(99) connection: ConnectionStatus state transition old_state=Connecting new_state=WaitingForIdentity connection_id=1 profile=Alpha
    2026-01-02T03:04:12.000000Z  INFO ThreadId(99) connection: ConnectionStatus state transition old_state=Connecting new_state=Connected connection_id=1 profile=Alpha
    """
check(
    "a sign-in that is merely starting is not a teardown",
    readTeardown(normalSignIn) == nil
)

// The other trap, and the one that already cost a wrong hypothesis. This
// arrives in the server's pushed options on every successful connect, so
// matching the words reports a keepalive timeout on every good tunnel.
let pushedOptions = """
    2026-01-02T03:04:05.000000Z  INFO ThreadId(99) connection: OpenVPN callback Log(OvpnLog { text: "OPTIONS:\\n0 [ping-restart] [120]\\n1 [comp-lzo] [no]\\n" }) profile=Alpha
    """
check(
    "a pushed ping-restart option is not a teardown",
    readTeardown(pushedOptions) == nil
)

check(
    "a reconnect that meets a challenge is a teardown",
    readTeardown("""
        2026-01-02T03:04:06.000000Z  INFO ThreadId(99) connection: ConnectionStatus state transition old_state=Reconnecting new_state=WaitingForIdentity connection_id=1 profile=Bravo
        """)?.cause == .signInRequired
)
check(
    "a rejected server address is its own cause",
    readTeardown("""
        2026-01-02T03:04:06.000000Z  INFO ThreadId(99) connection: ServerIpValidationFailed profile=Bravo
        """)?.cause == .serverAddressRejected
)
check("an empty log yields nothing", readTeardown("") == nil)
check(
    "and text carrying no marker yields nothing",
    readTeardown("2026-01-02T03:04:05.000000Z  INFO nothing happened here") == nil
)

// Two sessions hours apart. The newest is the one worth reporting, and the
// older one must not be dragged in as its cause — which is why the look-back
// for an initiating event is bounded by time.
let twoSessions = """
    2026-01-02T01:00:00.000000Z  INFO tokio-rt-worker ThreadId(13) LocalNet: new LAN detected, stopping session
    2026-01-02T05:00:00.000000Z  INFO ThreadId(99) connection: ConnectionStatus state transition old_state=Reconnecting new_state=WaitingForIdentity connection_id=1 profile=Bravo
    """
check(
    "an older unrelated teardown is not adopted as the cause of a newer one",
    readTeardown(twoSessions)?.cause == .signInRequired
)

// The file half. The sandbox denies subprocesses but not files, so the whole
// path is reachable here rather than only its middle.
let daemonLogs = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("conduit-smoke-daemon-logs")
try? FileManager.default.removeItem(at: daemonLogs)
try? FileManager.default.createDirectory(
    at: daemonLogs, withIntermediateDirectories: true
)
try? data(localNetLog).write(
    to: daemonLogs.appendingPathComponent("aws_vpn_client_daemon_20260830.log")
)
try? data(twoSessions).write(
    to: daemonLogs.appendingPathComponent("aws_vpn_client_daemon_20260830.log.1")
)

// The number inside the name looks like a date and is not one — it did not move
// across eight days of observed rotation. So the live file is told from its
// history by the extension, and never by building a name from today.
check(
    "the live log is chosen over a rotation",
    DaemonLog.newest(in: daemonLogs)?.lastPathComponent
        == "aws_vpn_client_daemon_20260830.log"
)
check(
    "and reading the directory yields the teardown recorded in it",
    DaemonLog.latestTeardown(in: daemonLogs)?.cause == .localNetworkChanged
)
check(
    "an absent directory yields nothing rather than failing",
    DaemonLog.latestTeardown(
        in: daemonLogs.appendingPathComponent("missing")
    ) == nil
)

let tailFixture = daemonLogs.appendingPathComponent("tail-fixture.txt")
try? data("first line\nsecond line\nthird line\n").write(to: tailFixture)
// An offset chosen in bytes lands mid-line, and a partial line is not worth
// parsing.
check(
    "a tail starting mid-file drops the partial line it landed in",
    DaemonLog.tail(of: tailFixture, bytes: 16)?.hasPrefix("third line") == true
)
check(
    "a tail covering the whole file keeps its first line",
    DaemonLog.tail(of: tailFixture, bytes: 4096)?.hasPrefix("first line") == true
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
