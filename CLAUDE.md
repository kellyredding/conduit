# Conduit

A macOS menu-bar client for AWS Client VPN (`ConduitApp/`) and its companion
Crystal CLI (`tools/conduit-vpn/`). Both drive the AWS VPN Client's own
command-line interface as a subprocess.

## This repository is public

The code drives a VPN client, but it must never describe anyone's particular
VPN. Never commit — in source, comments, specs, fixtures, documentation,
configuration, or commit messages:

- Profile names. They arrive from the client at runtime.
- Endpoint addresses, routed ranges, or resolver addresses. Read them from the
  OS when they need to be displayed.
- Identity-provider names, single-sign-on endpoints, or account identifiers.
- Usernames, hostnames, or employer names.

Spec fixtures use invented profile names: `Alpha`, `Bravo`, `Charlie`, `Delta`.

`make audit` enforces this and runs as part of `make check`. It has two
layers: structural patterns in `scripts/check-disclosure.sh`, which describe
the *shape* of a leak and so catch cases nobody anticipated; and a literal
denylist kept deliberately outside the repository, since a committed list of
forbidden strings would be the disclosure it prevents. Point at it with
`CONDUIT_DENYLIST`, or leave it at `~/.conduit/denylist.txt`.

**The audit scans git-*tracked* files only.** A new file is invisible to it
until staged, so writing one, running `make audit`, and reading "clean" proves
nothing at all. Stage first, then audit.

A leak that reaches a commit is not fixable by a follow-up commit — git keeps
the object. Run the audit before committing, not after.

On a fresh clone the denylist is absent and the audit refuses rather than
covering less than it claims. `SETUP.md` documents
`CONDUIT_ALLOW_NO_DENYLIST=1` for that case.

## Building

```bash
make check       # CLI gate:  audit + lint + test + build
make app-check   # app gate:  build + sandboxed smoke checks
make dev         # fast unoptimized CLI binary at tools/conduit-vpn/build/
make build       # CLI + app
```

**`make check` does not cover the app.** It is the audit plus the CLI's gate,
and `make app-check` is separate — so a change touching both sides needs both
commands. Running only the first on a Swift change reports success having
compiled none of it.

Crystal resolves through mise shims, so `crystal` and `shards` are called
directly. The version is pinned in `.tool-versions`.

`ConduitApp/project.yml` is the source of truth for the Xcode project, which
`xcodegen` regenerates on every build and which is not tracked. Never run
`xcodebuild` directly and never hand-edit the `.xcodeproj`.

**`ConduitApp/Models/` must stay Foundation-only.** The sandboxed `VPNSmoke`
check target compiles exactly that directory and nothing else, which is what
lets the model layer be exercised without a window server, a subprocess, or a
tunnel. Anything importing AppKit or SwiftUI belongs in `Services/` or
`Views/`; putting a parser there instead costs it every check in the suite.

`** BUILD SUCCEEDED **` proves nothing about whether the coding keys still match
what the client emits — that failure surfaces at runtime as an empty menu, which
is why the smoke target exists.

## Mirror contract

These pairs are one contract expressed in two languages. Changing one without
the other silently desynchronizes the CLI from the app:

| Crystal | Swift |
|---|---|
| `tools/conduit-vpn/src/conduit_vpn/paths.cr`  | `ConduitApp/ConduitApp/Models/Paths.swift`  |
| `tools/conduit-vpn/src/conduit_vpn/config.cr` | `ConduitApp/ConduitApp/Models/Config.swift` |
| `tools/conduit-vpn/src/conduit_vpn/models.cr` | `ConduitApp/ConduitApp/Models/VPNTypes.swift` |

## Facts about the client that shape the code

- **`connect` is asynchronous.** It reports that an attempt started and exits
  0 immediately. That is not success. Poll `get-connection-status` to a
  terminal state.
- **`NotConnected` is ambiguous** — it means both "idle" and "the attempt you
  just made failed". Disambiguate by whether progress was observed.
- **`disconnect` prints nothing on success.** The exit code is the only signal.
- **Errors arrive on stdout**, not stderr, as `{"status":"Error","message":…}`
  with exit 1.
- **`details` is not a signal of connectedness.** It is absent for an idle
  profile, but a stalled attempt returns it *present with every counter zero*.
  Keep it optional and never default the counters to zero: that exact payload
  arrives from the client, and a zeroed default is indistinguishable from it.
- **A stalled attempt blocks its own replacement.** After a wake the client
  starts an attempt nobody asked for, and if the network has not returned it
  parks in `WaitingForIdentity` for about ten minutes. Throughout, `connect`
  exits 1 with `Already connected to profile` while no tunnel exists at all —
  no route, no interface address, no bytes. `disconnect` clears it instantly
  and a `connect` then succeeds. Read the state, never the sentence.
- **Several connections can be live at once.** Not a single-valued state.
- **Conduit is never the only actor.** Connections are created and destroyed
  by other tools. Reconcile against the client continuously; never assume a
  state because Conduit asked for it.

## Do not

- Connect or disconnect a profile unless explicitly asked. Reading status is
  always fine.
- Talk to the client's daemon directly. It validates callers by code
  signature, so a third-party binary cannot connect.
- Health-check a connection by public IP. Tunnels are split, so an unchanged
  public IP is expected and proves nothing.
