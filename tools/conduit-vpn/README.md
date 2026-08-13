# conduit-vpn

The command-line half of [Conduit](../../README.md): a Crystal binary that drives
the AWS VPN Client's own CLI with a corrected `HOME`, adds the behaviours that
client leaves to its callers, and forwards everything else untouched.

Usable on its own. The menu-bar app is not required, and the two never talk to
each other — see [How it works](../../README.md#how-it-works).

## Commands

Three tiers, and which tier a command belongs to tells you how much Conduit is
involved.

**Conduit's own:**

| Command | Description |
|---|---|
| `status` | Every profile and its connection state, one line each. `--json` for machine output |
| `config` | Read and write settings. `get`, `set`, `unset`, `describe`, `example` |
| `doctor` | Whether this machine is set up correctly. `--explain` describes the addressing failure |
| `version` | The `conduit-vpn` version |

**Client commands Conduit adds to.** Every flag the client accepts still works,
and without Conduit's own flags the behaviour is the client's:

| Command | Additions |
|---|---|
| `connect` | `--wait` to watch to a terminal state, `--yes` to confirm a marked profile, `--timeout N` |
| `disconnect` | `--wait`, `--timeout N` |

**Forwarded unchanged:** `get-connection-status`, `list-connections`,
`list-profiles`, `get-config`, `import-profile`, `delete-profile`,
`list-preferences`, `put-preference`, `send-diagnostic-logs`.

Those are **enumerated rather than passed through by default**. Treating anything
unrecognized as forwardable would mean a mistyped command produced an opaque
usage dump from a binary the caller did not think they were invoking; instead it
reports its own name back. The cost is that a command added by a future client
release needs a line here before it can be reached.

## Usage

```bash
# What is connected, and what needs confirmation before connecting
conduit-vpn status

# Connect and wait for a real answer
conduit-vpn connect --profile-name Alpha --wait

# A profile the sensitivity pattern marks is refused without --yes
conduit-vpn connect --profile-name Bravo --wait --yes

# Tear down, and wait until it is actually gone
conduit-vpn disconnect --profile-name Alpha --wait

# Is this machine able to reach the client at all
conduit-vpn doctor
```

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success |
| `1` | Failure — the command ran and did not achieve its purpose |
| `2` | Usage error. Matches the client's own convention, so a caller that already special-cases it keeps working when a command is forwarded |
| `3` | `--wait` stopped watching. **Not a failure** |

`3` exists because a timeout and a failure must not share a code. Sign-in happens
in a browser, so giving up watching says nothing about whether the attempt will
still succeed — and a caller that conflates the two retries something already in
progress.

## What `--wait` is for

The client's `connect` reports that an attempt *started* and exits 0
immediately. That is not success, so every caller ends up writing the same
polling loop, and the naive version gets it wrong: `NotConnected` means both
"idle" and "the attempt you just made failed", and idle readings arrive for a
second or two after an attempt begins. A loop that treats the first of those as
failure reports a loss on a connection that is about to succeed.

`--wait` polls to a terminal state, tolerates those early idle readings, narrates
progress on stderr, and prints one JSON object on stdout:

```json
{
  "profile-name": "Alpha",
  "outcome": "connected",
  "elapsed-seconds": 9.5
}
```

`connect` also releases any other live tunnel first, so a deployment routed for
one connection at a time behaves that way regardless of which surface asked.

## Settings

Resolution order, highest first:

```
flag  >  environment variable  >  ~/.conduit/config.json  >  compiled default
```

The file records only what differs from a default, so improving a default in
code reaches an existing install rather than being shadowed by a value written at
install time. An absent, empty, or partial file is the normal case.

```bash
conduit-vpn config              # every value and the layer it came from
conduit-vpn config describe     # what each key means, and its variable
conduit-vpn config example      # a documented file, on stdout
```

`set` reports when a variable outranks the file, because writing a value that
does not take effect is otherwise a long hunt.

## Data

- `~/.conduit/bin/conduit-vpn` — installed binary, symlinked onto `~/.local/bin`
- `~/.conduit/config.json` — settings, shared with the app. Created on first change
- `~/.conduit/config.example.json` — written at install, never read back
- `~/.conduit/client-home` — the `HOME` handed to the vendor client; only its logs
  live there, and it must be reachable without traversing a symlink

## Development

```bash
make check    # format, build dev binary, run specs, lint
make install  # release binary + ~/.local/bin symlink
```

Specs are split: `spec/conduit_vpn/` exercises modules directly, and
`spec/integration/` runs the compiled binary against a fake `aws-vpn-client` on
`PATH` (`spec/fixtures/bin/`), so nothing in the suite talks to a real client or
a real tunnel.

The repository is public and the disclosure audit runs as part of `make check`
from the repository root. Fixtures use invented profile names — `Alpha`, `Bravo`,
`Charlie`, `Delta` — and never real addresses. See the root
[`CLAUDE.md`](../../CLAUDE.md).

## License

MIT
