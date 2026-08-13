# Conduit

A macOS menu-bar client for AWS Client VPN, plus a companion CLI.

- `tools/conduit-vpn/` — Crystal CLI (`conduit-vpn` binary)
- `ConduitApp/` — Swift menu-bar app

Both drive the AWS VPN Client's own command-line interface, which ships with
client version 6.0 and later.

## Why this exists

The vendor's GUI derives its log directory from `$HOME` and refuses to start
unless that path contains no symlinks. On a machine where `~/.config` is a
symlink — a common arrangement for dotfile syncing — the GUI aborts at launch
and cannot be fixed from outside, because it is started by Finder and always
inherits the real `$HOME`.

Conduit runs the vendor CLI with a corrected `HOME`, which satisfies the
check. Nothing else in the client reads `$HOME`: profiles are stored under
`/Library/Application Support` and the daemon socket is system-wide, so the
override changes only where the client writes its own logs.

It also fills gaps in the vendor CLI. `connect` is asynchronous — it reports
that an attempt *started*, not that it succeeded — so every caller ends up
hand-rolling a polling loop. Profiles that warrant extra care before connecting
are protected only by convention. Nothing keeps a second tunnel from being
requested on a deployment routed for one. And the client writes a log file per
day and removes none of them.

## What it does

### In the menu bar

The icon reports connectivity, separating states by **shape** rather than
colour so they stay legible at menu-bar size and follow light and dark
automatically. Opening the panel lists every profile with its state, and
connect or disconnect is one click.

- **One tunnel at a time.** Connecting releases any other live tunnel first,
  rather than failing with a message that describes a limit and leaves you to
  tidy up by hand.
- **A confirmation on the profiles that warrant one**, matched by a pattern you
  configure — enforced by the CLI too, so it is not honour-system.
- **Notifications for changes nobody watched.** Tunnels come and go from
  terminals and from other tools; a change you made yourself in the panel is
  not announced back to you.
- **Connections are re-established after sleep**, once the network is genuinely
  back rather than when the machine wakes — the client's own attempt fires too
  early, fails, and then holds the profile against replacement for ten minutes.
- **Settings (`⌘,`)** for the sensitivity pattern, polling cadence, appearance,
  and log retention. The same file the CLI reads.
- **Connection Details (`⌘D`)** — throughput history differenced from the
  client's cumulative counters, the routes each tunnel installs, the resolvers
  the OS reports and which interface actually reaches them, and a log of the
  transitions this process observed.
- **The client's own logs are pruned** on a schedule, by retention and by total
  size. Nothing else does this.

### On the command line

```bash
conduit-vpn status                                   # every profile, one line each
conduit-vpn connect --profile-name Alpha --wait      # exit 0/1/3, not "started"
conduit-vpn disconnect --profile-name Alpha --wait
conduit-vpn doctor                                   # is this machine set up
```

`--wait` polls to a terminal state so the exit code means something: `0`
connected, `1` did not connect, `3` gave up watching while sign-in may still be
pending in a browser. That last one is deliberately not a failure — conflating
the two makes callers retry something already in progress.

Every command the vendor CLI provides is forwarded unchanged, so `conduit-vpn`
is a drop-in replacement rather than a subset.

## How it works

Three deliberate choices, and the first is the unusual one:

**The CLI and the app do not talk to each other.** There is no socket and no
daemon. Both drive the vendor binary as a subprocess and both read the same
settings file, so either works with the other absent, and neither has to be
running for the other to be correct.

**The model layer is mirrored, not shared.** Crystal and Swift each carry their
own copy of the paths, the settings keys, and the client's payload shapes. That
is a contract expressed twice — `CLAUDE.md` lists the pairs — and it is the
price of two languages driving one client.

**Nothing assumes Conduit is the only actor.** Connections are created and
destroyed by other tools and are often already live at launch, so state is
reconciled against the client continuously rather than inferred from what
Conduit asked for.

## Setup

See [SETUP.md](SETUP.md) — prerequisites, building the CLI and the app, the
disclosure audit, and troubleshooting.

```bash
make cli-install      # build + install ~/.local/bin/conduit-vpn
conduit-vpn doctor    # verify the install
```

## Configuration

Settings resolve in this order:

```
flag  >  environment variable  >  ~/.conduit/config.json  >  compiled default
```

`~/.conduit/config.json` is created only when a value is changed, and records
only what differs from the defaults — so an improved default reaches an
existing install rather than being shadowed by a value written at install
time. A missing, empty, or partial file is normal.

```bash
conduit-vpn config                    # every value, and where it came from
conduit-vpn config set <key> <value>
conduit-vpn config unset <key>
```

`~/.conduit/config.example.json` documents every key. It is never read.

## Development

```bash
make check                 # CLI gate: disclosure audit + lint + test + build
make app-check             # app gate: build + smoke checks
make build                 # CLI + app
```

`make check` does **not** cover the app, and `make app-check` does not cover the
CLI — a change touching both needs both commands.

This repository is public and must never describe anyone's particular VPN.
`make audit` enforces that and runs as part of `make check`; it scans
git-*tracked* files, so a new file is invisible to it until staged.
[SETUP.md](SETUP.md) explains the denylist a fresh clone does not have, and
`CLAUDE.md` carries the full rule along with the client behaviours that shape
the code.

## License

MIT
