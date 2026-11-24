#!/usr/bin/env bash
# Usage: sign-app.sh (op|adhoc) <target>...
#
# A target is a bundle's path, or <identifier>=<path> for a bare binary, whose
# identifier would otherwise be its file name. Every target is signed in one
# session, so the release identity costs one 1Password approval for the app
# and the CLI together.
#
# op:    signs with the release identity, fetched from 1Password into a
#        throwaway keychain that is deleted on exit. The login keychain is
#        never used: a key there needs the user's login password, which
#        surfaces as a dialog mid-build.
# adhoc: signs with no identity, so macOS treats every build as a new app.
#        For checking that packaging works; never for anything installed.
set -euo pipefail

usage="usage: sign-app.sh (op|adhoc) <path|identifier=path>..."
mode="${1:?$usage}"
shift
(( $# > 0 )) || { echo "$usage" >&2; exit 2; }

OP_ACCOUNT="${CONDUIT_SIGNING_OP_ACCOUNT:-my.1password.com}"
OP_ITEM="${CONDUIT_SIGNING_OP_ITEM:-op://Private/Conduit Release Signing}"

# Splits a target into its path and the --identifier arguments it needs. An
# identifier is a reverse-DNS name, so a path that merely contains "=" is
# taken whole.
cn_target() {
  local target="$1"
  if [[ "$target" =~ ^([A-Za-z0-9.-]+)=(.+)$ ]]; then
    target_path="${BASH_REMATCH[2]}"
    target_args=(--identifier "${BASH_REMATCH[1]}")
  else
    target_path="$target"
    target_args=()
  fi
  [[ -e "$target_path" ]] || { echo "sign-app.sh: no such file: $target_path" >&2; exit 1; }
}

if [[ "$mode" == "adhoc" ]]; then
  for target in "$@"; do
    cn_target "$target"
    codesign --force --sign - --timestamp=none ${target_args[@]+"${target_args[@]}"} "$target_path" 2>&1 \
      | { grep -v "replacing existing signature" || true; }
  done
  exit 0
fi
[[ "$mode" == "op" ]] || { echo "sign-app.sh: unknown mode '$mode'" >&2; exit 2; }
for target in "$@"; do cn_target "$target"; done

work="$(mktemp -d)"
kc="$work/conduit-signing.keychain-db"
kcpass="$(/usr/bin/openssl rand -hex 24)"

orig_list=()
while IFS= read -r line; do
  line="${line#"${line%%[![:space:]]*}"}"; line="${line%\"}"; line="${line#\"}"
  [[ -n "$line" ]] && orig_list+=("$line")
done < <(security list-keychains -d user)

# shellcheck disable=SC2329 # run by the trap below
cn_cleanup() {
  security list-keychains -d user -s ${orig_list[@]+"${orig_list[@]}"} || true
  security delete-keychain "$kc" 2>/dev/null || true
  rm -rf "${work:?}"
}
trap cn_cleanup EXIT

# op gives up on the desktop app within a few seconds, often while its
# approval prompt is still on screen, so retry until the approval lands.
last_error=""
for attempt in $(seq 1 20); do
  # bin/signing-identity stores the file as field `p12` in section `signing`.
  if last_error="$(op read --account "$OP_ACCOUNT" --out-file "$work/signing.p12" --force "$OP_ITEM/signing/p12" 2>&1 >/dev/null)"; then
    break
  fi
  if (( attempt == 1 )); then
    echo "Approve the 1Password prompt to sign Conduit (op said: $last_error)" >&2
  fi
  if (( attempt == 20 )); then
    echo "1Password never provided the signing identity. Last error from op: $last_error" >&2
    echo "Run it from a terminal that can show 1Password's prompt; bin/signing-identity show checks the item exists." >&2
    exit 1
  fi
  sleep 3
done
p12pass="$(op read --account "$OP_ACCOUNT" "$OP_ITEM/password")"
identity="$(op read --account "$OP_ACCOUNT" "$OP_ITEM/sha1")"

security create-keychain -p "$kcpass" "$kc"
# No auto-lock and no lock on sleep: a keychain that locks mid-run raises a
# password dialog for a password no one knows.
security set-keychain-settings "$kc"
security unlock-keychain -p "$kcpass" "$kc"
security import "$work/signing.p12" -k "$kc" -P "$p12pass" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$kcpass" "$kc" >/dev/null
# codesign --keychain only searches keychains already on the search list.
security list-keychains -d user -s ${orig_list[@]+"${orig_list[@]}"} "$kc"

for target in "$@"; do
  cn_target "$target"
  codesign --force --keychain "$kc" --sign "$identity" --timestamp=none \
    ${target_args[@]+"${target_args[@]}"} "$target_path" 2>&1 \
    | { grep -v "replacing existing signature" || true; }
done
