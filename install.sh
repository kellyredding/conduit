#!/usr/bin/env bash
# Installs or updates Conduit: the conduit-vpn CLI and Conduit.app.
#
#   curl -fsSL https://raw.githubusercontent.com/kellyredding/conduit/main/install.sh | bash
#
# `conduit-vpn update` runs this same script. Options (after `bash -s --` when piped):
#
#   --version X.Y.Z   Install that release instead of the latest
#   --from ARCHIVE    Install a local archive written by bin/package
#   --preview         Show what would change, change nothing
#   --force           Reinstall even when already up to date
#   --no-register     Skip Launch Services registration (sandboxed tests)
#
# Never launches, quits or restarts Conduit, and never touches settings
# (~/.conduit/config.json), the client home or the denylist.

# One compound command, so bash reads all of it before running any: piped in,
# a truncated download or a command that reads stdin would otherwise cut the
# script short partway through an install.
{
set -euo pipefail

REPO="kellyredding/conduit"
ASSET="conduit-darwin-arm64.tar.gz"
IDENTITY="Conduit Release Signing"
MIN_MACOS=26
CONDUIT_HOME="${CONDUIT_ROOT:-$HOME/.conduit}"
BIN_DIR="$CONDUIT_HOME/bin"
LOCAL_BIN="$HOME/.local/bin"
APP_DIR="$HOME/Applications"
APP="$APP_DIR/Conduit.app"
INSTALLED_MANIFEST="$CONDUIT_HOME/installed-manifest.json"
EXAMPLE_CONFIG="$CONDUIT_HOME/config.example.json"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister

version=""
from=""
preview=false
force=false
register=true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) version="${2:?--version needs X.Y.Z}"; version="${version#v}"; shift ;;
    --from) from="${2:?--from needs an archive path}"; shift ;;
    --preview|preview) preview=true ;;
    --force|force) force=true ;;
    --no-register) register=false ;;
    # Piped in, $0 is the shell rather than this file.
    -h|--help|help) if [[ -f "$0" ]]; then sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
                    else echo "See https://github.com/$REPO/blob/main/install.sh"; fi; exit 0 ;;
    *) echo "install.sh: unknown option '$1'" >&2; exit 2 ;;
  esac
  shift
done
if [[ -n "$from" && -n "$version" ]]; then
  echo "install.sh: --from installs that archive; it cannot be combined with --version" >&2
  exit 2
fi

if [[ -t 1 ]]; then BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; NC=$'\033[0m'
else BOLD=""; RED=""; GREEN=""; NC=""; fi
say() { printf '%s\n' "$*"; }
step() { printf '  %s\n' "$*"; }
die() { printf '%sinstall.sh: %s%s\n' "$RED" "$*" "$NC" >&2; exit 1; }

# --- This Mac ----------------------------------------------------------------

[[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]] \
  || die "Conduit releases are built for Apple Silicon Macs only; this is $(uname -s) on $(uname -m)."
macos="$(sw_vers -productVersion)"
(( ${macos%%.*} >= MIN_MACOS )) || die "Conduit needs macOS $MIN_MACOS or later; this Mac runs $macos."

work="$(mktemp -d)"
installed_ok=false
# shellcheck disable=SC2329 # run by the trap below
cn_cleanup() {
  if $installed_ok || $preview; then rm -rf "${work:?}"
  else printf 'Working files kept for inspection: %s\n' "$work" >&2; fi
}
trap cn_cleanup EXIT

# --- Fetch -------------------------------------------------------------------

if [[ -n "$from" ]]; then
  [[ -f "$from" ]] || die "no archive at $from"
  cp "$from" "$work/$ASSET"
  # Renamed to the fixed name, so an archive saved under another name still
  # checks against its own checksum file.
  if [[ -f "$from.sha256" ]]; then
    sed "s/[^ ]*$/$ASSET/" "$from.sha256" > "$work/$ASSET.sha256"
  fi
  source_label="$from"
else
  if [[ -n "$version" ]]; then
    base="https://github.com/$REPO/releases/download/v$version"
  else
    base="https://github.com/$REPO/releases/latest/download"
  fi
  # curl rather than a browser download: curl sets no quarantine flag, which
  # is what lets a self-signed Conduit.app open without a Gatekeeper prompt.
  curl -fsSL "$base/$ASSET" -o "$work/$ASSET" </dev/null \
    || die "could not download $base/$ASSET${version:+ (is v$version a Conduit release?)}"
  curl -fsSL "$base/$ASSET.sha256" -o "$work/$ASSET.sha256" </dev/null \
    || die "could not download the checksum for $ASSET"
  source_label="$base"
fi

if [[ -f "$work/$ASSET.sha256" ]]; then
  (cd "$work" && shasum -a 256 -c "$ASSET.sha256" >/dev/null) \
    || die "checksum mismatch for $ASSET; nothing was installed"
elif [[ -z "$from" ]]; then
  die "no checksum for $ASSET; nothing was installed"
fi

mkdir -p "$work/unpacked"
tar -xzf "$work/$ASSET" -C "$work/unpacked" || die "could not unpack $ASSET"
pkg="$work/unpacked/conduit"
[[ -f "$pkg/manifest.json" && -f "$pkg/bin/conduit-vpn" && -d "$pkg/Conduit.app" ]] \
  || die "$ASSET is not a Conduit release archive"

# Only the release identity is installed, so every install carries one
# signature and what macOS ties to it carries over. Refused before anything
# is replaced.
for target in "$pkg/Conduit.app" "$pkg/bin/conduit-vpn"; do
  codesign --verify --strict "$target" 2>/dev/null \
    || die "$(basename "$target") in $ASSET does not verify; nothing was installed"
  signature="$(codesign -dv --verbose=2 "$target" 2>&1)"
  [[ "$signature" == *$'\n'"Authority=$IDENTITY"$'\n'* ]] \
    || die "$(basename "$target") in $ASSET is not signed by $IDENTITY. Package it with bin/package (--sign op); nothing was installed"
done

manifest_field() { sed -n "s/^  \"$1\": \"\{0,1\}\([^\",]*\)\"\{0,1\},\{0,1\}$/\1/p" "$2" | sed -n 1p; }
new_version="$(manifest_field version "$pkg/manifest.json")"
new_commit="$(manifest_field commit "$pkg/manifest.json")"
new_dirty="$(manifest_field dirty "$pkg/manifest.json")"
if [[ -f "$INSTALLED_MANIFEST" ]]; then
  cur_version="$(manifest_field version "$INSTALLED_MANIFEST")"
  cur_commit="$(manifest_field commit "$INSTALLED_MANIFEST")"
  cur_dirty="$(manifest_field dirty "$INSTALLED_MANIFEST")"
elif [[ -x "$BIN_DIR/conduit-vpn" ]]; then
  cur_version="unknown (installed from source)"; cur_commit=""; cur_dirty=""
else
  cur_version="not installed"; cur_commit=""; cur_dirty=""
fi
first_app=false
[[ -e "$APP" || -L "$APP" ]] || first_app=true
app_linked=false
[[ -L "$APP" ]] && app_linked=true

describe() { printf '%s' "$1"; [[ -n "$2" ]] && printf ' (%s%s)' "$2" "$([[ "$3" == true ]] && echo ', uncommitted changes')"; }

# A release is up to date when it is the same commit with no local edits.
# --from always installs, because a local archive is installed on purpose.
if [[ -z "$from" ]] && ! $force && ! $preview && ! $app_linked \
   && [[ -n "$cur_commit" && "$cur_commit" == "$new_commit" && "$cur_dirty" != "true" ]]; then
  say "${GREEN}Conduit is up to date: $(describe "$cur_version" "$cur_commit" "$cur_dirty")${NC}"
  installed_ok=true
  exit 0
fi

say "${BOLD}$([[ "$cur_version" == "not installed" ]] && echo Installing || echo Updating) Conduit${NC}"
step "From:      $source_label"
step "Installed: $(describe "$cur_version" "$cur_commit" "$cur_dirty")"
step "New:       $(describe "$new_version" "$new_commit" "$new_dirty")"
step "CLI:       $BIN_DIR/conduit-vpn (linked into $LOCAL_BIN)"
if $app_linked; then
  step "App:       $APP (replacing a link to $(readlink "$APP"); its target is left alone)"
else
  step "App:       $APP"
fi
step "Signed by: $IDENTITY"

if $preview; then
  say ""
  say "Preview only: nothing was changed. Run without --preview to install."
  exit 0
fi
say ""

# --- Install -----------------------------------------------------------------

mkdir -p "$BIN_DIR" "$LOCAL_BIN" "$APP_DIR"

# A new file moved over the old one, rather than copied onto it, so a binary
# that is running keeps its pages and macOS sees a fresh signature.
install -m 755 "$pkg/bin/conduit-vpn" "$BIN_DIR/.conduit-vpn.new"
mv -f "$BIN_DIR/.conduit-vpn.new" "$BIN_DIR/conduit-vpn"
# Replaces a plain file a source install may have left here, too.
ln -sfn "$BIN_DIR/conduit-vpn" "$LOCAL_BIN/conduit-vpn"
step "Installed conduit-vpn"

# Documents every setting and is never read back, so it is rewritten to match
# the defaults of the binary just installed.
CONDUIT_ROOT="$CONDUIT_HOME" "$BIN_DIR/conduit-vpn" config example > "$EXAMPLE_CONFIG.new" </dev/null \
  || die "conduit-vpn config example failed"
mv -f "$EXAMPLE_CONFIG.new" "$EXAMPLE_CONFIG"
step "Wrote $EXAMPLE_CONFIG"

# Swapped by rename: a running Conduit keeps running from its old bundle, and
# the next launch opens the new one. A link to a build folder is removed as a
# link, with no trailing slash, so nothing inside its target is touched.
rm -rf "${APP:?}.new" "${APP:?}.old"
ditto "$pkg/Conduit.app" "$APP.new"
if [[ -L "$APP" ]]; then
  rm "${APP:?}"
elif [[ -e "$APP" ]]; then
  mv "$APP" "$APP.old"
fi
mv "$APP.new" "$APP"
rm -rf "${APP:?}.old"
step "Installed Conduit.app"

if $register; then
  "$LSREGISTER" -f "$APP"
  # Copies left in an Xcode build folder share the bundle id, so leave the
  # installed one the only Conduit.app registered.
  while IFS= read -r stale; do
    "$LSREGISTER" -u "$stale" 2>/dev/null || true
    step "Unregistered $stale"
  done < <("$LSREGISTER" -dump 2>/dev/null \
             | sed -n 's/^path: *\(.*\/Build\/Products\/[^/]*\/Conduit\.app\) (0x[0-9a-f]*)$/\1/p' \
             | sort -u)
fi

# Last, so a record only ever describes an install that finished.
cp "$pkg/manifest.json" "$INSTALLED_MANIFEST.new"
mv -f "$INSTALLED_MANIFEST.new" "$INSTALLED_MANIFEST"
installed_ok=true

# --- Next steps --------------------------------------------------------------

say ""
say "${GREEN}Conduit $(describe "$new_version" "$new_commit" "$new_dirty") is installed.${NC}"
case ":$PATH:" in
  *":$LOCAL_BIN:"*) ;;
  *) say "Add $LOCAL_BIN to your PATH to use conduit-vpn." ;;
esac
# Forget where conduit-vpn was found before the install, so this looks again.
hash -r
on_path="$(command -v conduit-vpn || true)"
if [[ -n "$on_path" && "$on_path" != "$LOCAL_BIN/conduit-vpn" && "$on_path" != "$BIN_DIR/conduit-vpn" ]]; then
  say "$on_path comes first on your PATH and is not this install; remove it."
fi
if $first_app; then
  say "Open Conduit with: open \"$APP\""
  say "It lives in the menu bar, and asks to post notifications on first launch."
else
  say "A running Conduit keeps the old build until you restart it; restart it when you're ready to switch."
fi
exit 0
}
