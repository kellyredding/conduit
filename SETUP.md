# Setup

Building Conduit from source: the `conduit-vpn` command line, the menu-bar app,
or both. They are independent — the CLI is useful on its own, and the app needs
nothing from it at runtime.

## Prerequisites

- macOS 14 or later
- **AWS VPN Client 6.0 or later**, installed in `/Applications`. The command-line
  interface this drives first ships with 6.0; a 5.x install has no CLI at all,
  and Homebrew's cask tracked 5.x for a long time. Check with:
  `defaults read "/Applications/AWS VPN Client/AWS VPN Client.app/Contents/Info.plist" CFBundleShortVersionString`
- At least one VPN profile imported into the client. Conduit never provisions
  profiles — it reads whatever the client already knows about.
- **Crystal 1.18.2** (pinned in `.tool-versions`) and `shards`, for the CLI
- **Xcode** and **`xcodegen`**, for the app

## Clone

```bash
git clone https://github.com/kellyredding/conduit.git
cd conduit
```

## 1. Build and install the CLI

```bash
make cli-install
```

**Where things land:**

- `~/.conduit/bin/conduit-vpn` — the release binary
- `~/.local/bin/conduit-vpn` — a symlink to it, for `PATH`
- `~/.conduit/config.example.json` — every setting documented; never read back

Make sure `~/.local/bin` is on your `PATH`.

## 2. Build the app

```bash
make app-build     # or: make app-check, to build and run the smoke checks
make app-install   # symlink into ~/Applications and register with Launch Services
open ~/Applications/Conduit.app
```

`ConduitApp/project.yml` is the source of truth for the Xcode project.
`xcodegen` regenerates it on every build and the `.xcodeproj` is not tracked, so
never edit it by hand and never call `xcodebuild` directly — the Makefile pins
`-derivedDataPath build` to keep output out of Xcode's global DerivedData.

Conduit is a menu-bar accessory: no Dock icon, no window, no `⌘-Tab` entry. Look
for the bolt in the menu bar. It is deliberately **not** `LSUIElement`, because
that key would also hide it from Launch Services and make it impossible to find
after a rebuild; the app sets `.accessory` at launch instead.

## The disclosure audit, on a fresh clone

`make check` runs `make audit`, which **fails on a fresh clone** — by design, and
this is the one step that surprises people:

```
FAILED — no literal denylist found.
```

This repository is public and must never describe anyone's particular VPN. The
audit has two layers: structural patterns committed here in
`scripts/check-disclosure.sh`, which describe the *shape* of a leak; and a list
of literal terms that cannot live in the repository, since a committed list of
forbidden strings would be the disclosure it prevents.

That file is absent from any clone, so the audit refuses rather than quietly
covering less than it claims. Two ways forward:

```bash
# Accept the structural checks alone — right for most people
CONDUIT_ALLOW_NO_DENYLIST=1 make check

# Or supply your own list: one extended-regex pattern per line
#   $CONDUIT_DENYLIST, else ~/.conduit/denylist.txt, else ./denylist.txt
```

If you keep the file in a synced directory, symlink the **file** into
`~/.conduit/` — never the directory itself. `~/.conduit/client-home` has to be
reachable without traversing a symlink or the vendor client refuses to start.

## Verify

```bash
conduit-vpn --version
conduit-vpn doctor    # client binary, client home, addressing, profiles
conduit-vpn status    # every profile and its state
```

`doctor` reports counts and never profile names, so its output is safe to paste
somewhere public.

## Troubleshooting

### `Log directory ... failed security validation: Path is not canonical`

The vendor client refuses to start when its log directory is reached through a
symlink, and it derives that directory from `$HOME`. This is the reason Conduit
exists: it runs the client with a corrected `HOME`, at
`~/.conduit/client-home` by default.

Seeing this from Conduit means that directory has itself acquired a symlinked
parent. `conduit-vpn doctor` names the path. Move it with
`conduit-vpn config set client-home <path>`.

### `make check` fails with `no literal denylist found`

Expected on a clone — see the audit section above.

### `list-profiles` returns `[]`

Either no profile was ever imported, or a client upgrade dropped the
registrations. Conduit does not provision profiles; import them with the vendor
client (`import-profile`) and they will appear.

### A profile reports `"auth-type": "ad"` and asks for a password

Its configuration file is missing the `auth-federate` directive, so the client
classified the endpoint as Active Directory instead of detecting federated
sign-in. A config exported from client 5.x will not have it — 5.x recorded that
in its own metadata rather than in the file. Add the directive above
`auth-user-pass` and re-import.

### `connect` exits 1 with `Already connected to profile`, but nothing works

A stalled attempt holds the profile against replacement for roughly ten minutes
while no tunnel exists at all — no route, no interface address, no bytes. The
client says the same sentence whether the profile is genuinely connected or
merely held.

`disconnect` clears it instantly, and a `connect` then succeeds. Read the state,
never the sentence.

### Connected, routes installed, but nothing on the far side is reachable

Check the profile's configuration for `proto udp4`:

```bash
conduit-vpn get-config --profile-name <name> | grep '^proto'
```

A config that says only `proto udp` lets the endpoint resolve to whatever the
network offers. On a network that synthesizes addresses for IPv4-only
destinations, the client then builds a tunnel that carries nothing — it reports
itself connected, installs its routes, and no traffic passes. Nothing errors,
which is what makes it expensive to diagnose.

Naming the address family explicitly fixes it. Re-import after editing.

### Connections fail on one network and succeed on another

Likely the same address-synthesis problem. `conduit-vpn doctor` reports the
condition, and `conduit-vpn doctor --explain` describes the mechanism.

### Connected, but the tunnel seems to carry almost nothing

Probably correct. These tunnels are usually **split**: only specific
destinations route through them, so ordinary browsing never touches the tunnel
and its byte counters barely move. The public IP stays unchanged, which means an
unchanged public IP proves nothing either way.

Connection Details (`⌘D`) says which it is, read from the routing table rather
than assumed — including whether any tunnel carries the default route.

### `** BUILD SUCCEEDED **` but the app misbehaves

A successful compile proves nothing about whether the model layer still decodes
what the client emits: a file full of `Codable` types compiles whether or not
its coding keys match reality, and that failure surfaces at runtime as an empty
menu. Run `make app-check`, which builds and then runs the sandboxed smoke
target against fixtures.

### The app does not appear in Spotlight or `open -a Conduit`

`make app-install` creates the `~/Applications` symlink and re-registers it. If
several copies have accumulated, list what Launch Services knows:

```bash
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -dump | grep -i "path.*Conduit.app"
```
