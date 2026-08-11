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

A leak that reaches a commit is not fixable by a follow-up commit — git keeps
the object. Run the audit before committing, not after.

## Building

```bash
make check     # audit + lint + test + build
make dev       # fast unoptimized binary at tools/conduit-vpn/build/
make install   # release binary + ~/.local/bin symlink
```

Crystal resolves through mise shims, so `crystal` and `shards` are called
directly. The version is pinned in `.tool-versions`.

Once the app exists: `ConduitApp/project.yml` is the source of truth for the
Xcode project, which `xcodegen` regenerates on every build. Never run
`xcodebuild` directly and never hand-edit the `.xcodeproj`.

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
- **`details` is absent** from a status response whenever the profile is not
  connected, even with `--show-details`. Keep it optional; never default the
  byte counters to zero.
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
