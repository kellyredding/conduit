#!/usr/bin/env bash
#
# check-disclosure.sh — refuse to ship deployment-specific details.
#
# This repository is public. The code drives a VPN client, but it must never
# describe anyone's particular VPN: no endpoint addresses, no routed ranges,
# no resolver addresses, no account identifiers, no profile names, no
# identity-provider names, no employer names. Everything environment-specific
# is runtime data, read from the client or from the OS.
#
# Two layers, because they fail differently:
#
#   1. STRUCTURAL patterns, defined here. These describe the *shape* of a
#      leak — a dotted quad, a CIDR block, an account identifier — so they
#      catch new leaks nobody thought to add to a list, and they can live in
#      a public repository because they name nothing.
#
#   2. A LITERAL denylist, deliberately NOT in this repository. It holds the
#      exact strings that must never appear here, which is precisely why
#      committing it would be the leak it exists to prevent. It is optional:
#      absent means the structural layer runs alone.
#
#        $CONDUIT_DENYLIST, else ~/.conduit/denylist.txt, else ./denylist.txt
#
#      One extended-regex pattern per line; blank lines and #-comments are
#      ignored. Matching is case-insensitive.
#
# Scans git-tracked files only, so build output and scratch files are out of
# scope. Exit 1 on any match.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

SELF="scripts/check-disclosure.sh"
found=0

# Report matches for one rule. Non-fatal individually so a single run
# surfaces every problem rather than only the first.
scan() {
  local label="$1" pattern="$2"
  shift 2

  local hits
  hits=$(git ls-files -z \
    | xargs -0 rg --no-messages --with-filename --line-number \
        --ignore-case --regexp "$pattern" -- 2>/dev/null \
    | rg -v "^$SELF:" || true)

  # Apply per-rule allowances (well-known non-identifying values).
  local allow
  for allow in "$@"; do
    hits=$(printf '%s\n' "$hits" | rg -v -F "$allow" || true)
  done

  [ -z "$hits" ] && return 0
  found=1
  printf '\n  %s\n' "$label"
  printf '%s\n' "$hits" | sed 's/^/    /'
}

echo "disclosure audit"

# A dotted quad is almost never legitimate in source here. Loopback, the
# unspecified address, and the broadcast address are the exceptions.
scan "network address literal" \
  '\b[0-9]{1,3}(\.[0-9]{1,3}){3}\b' \
  '0.0.0.0' '127.0.0.1' '255.255.255.255'

scan "routed range (CIDR)" \
  '\b[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}\b'

# The author's own address is intentional in package metadata.
scan "email address" \
  '[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}' \
  'kellyredding.com'

scan "cloud account identifier" '\b[0-9]{12}\b'
scan "cloud resource name"      'arn:[a-z-]*:'
scan "internal hostname"        '\.(internal|corp|intranet)\b'

# Layer 2: the literal list, kept outside the repository.
DENYLIST="${CONDUIT_DENYLIST:-}"
if [ -z "$DENYLIST" ]; then
  if [ -f "$HOME/.conduit/denylist.txt" ]; then
    DENYLIST="$HOME/.conduit/denylist.txt"
  elif [ -f "denylist.txt" ]; then
    DENYLIST="denylist.txt"
  fi
fi

if [ -n "$DENYLIST" ] && [ -f "$DENYLIST" ]; then
  # `rg --file` takes every line as a pattern — it has no notion of comments,
  # and a blank line is a pattern matching everything. Strip both before
  # handing the file over, or the denylist reports the entire repository.
  compiled=$(mktemp)
  trap 'rm -f "$compiled"' EXIT
  rg -v '^[[:space:]]*(#|$)' "$DENYLIST" > "$compiled" || true

  if [ -s "$compiled" ]; then
    hits=$(git ls-files -z \
      | xargs -0 rg --no-messages --with-filename --line-number \
          --ignore-case --file "$compiled" -- 2>/dev/null \
      | rg -v "^$SELF:" || true)
  else
    hits=""
  fi

  if [ -n "$hits" ]; then
    found=1
    printf '\n  denylisted term\n'
    printf '%s\n' "$hits" | sed 's/^/    /'
  fi
  echo "  denylist: $DENYLIST"
else
  # Refusing here rather than warning. A guard that quietly covers less than
  # it claims is worse than no guard: the structural layer alone would still
  # print "clean" and let the commit through, so a machine that was never set
  # up would silently lose the literal layer with no signal at all.
  cat <<'EOF'

FAILED — no literal denylist found.

The structural checks ran, but the terms that must never appear verbatim live
outside this repository and none was located. Looked for, in order:
  $CONDUIT_DENYLIST, ~/.conduit/denylist.txt, ./denylist.txt

On a configured machine the file is a symlink into the sync tree. To restore:
  mkdir -p ~/.conduit
  ln -s ~/Sync/<user>/conduit/denylist.txt ~/.conduit/denylist.txt

Symlink the file, never ~/.conduit itself — the client home beneath it has to
be reachable without traversing a symlink.

Working on a clone with no such list, and accepting structural checks alone:
  CONDUIT_ALLOW_NO_DENYLIST=1 make check
EOF
  [ "${CONDUIT_ALLOW_NO_DENYLIST:-}" = "1" ] || exit 1
  echo
  echo "  denylist: none — proceeding on CONDUIT_ALLOW_NO_DENYLIST"
fi

if [ "$found" -ne 0 ]; then
  cat <<'EOF'

FAILED — the matches above look deployment-specific.

This repository is public. Environment details belong at runtime, not in
source: profile names come from the client, routes and resolvers from the OS.
If a match is a false positive, add a narrow allowance in scripts/check-disclosure.sh
and say in the commit why it is safe.
EOF
  exit 1
fi

echo "  clean"
