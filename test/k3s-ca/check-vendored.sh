#!/usr/bin/env bash
# Verify that the vendored k3s CA library and test harness are identical to
# teknoir/cli at the commit recorded in test/k3s-ca/VENDORED_FROM.
#
#   test/k3s-ca/check-vendored.sh                 # fetch from GitHub with `gh api`
#   test/k3s-ca/check-vendored.sh --cli /path/to/cli   # use a local cli checkout (needs the commit)
#
# Checks:
#   templates/04_tn_k3s_ca_lib.sh  == 1 header line + cli pkg/templates/scripts/tn-k3s-ca.sh
#   test/k3s-ca/**                 == cli test/k3s-ca/** (local-only files are allowed)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CLI_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --cli) CLI_DIR="$2"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# shellcheck disable=SC1091
. "$HERE/VENDORED_FROM"   # REPO, SHA, LIB_PATH, HARNESS_PATH
[ -n "${SHA:-}" ] && [ -n "${REPO:-}" ] && [ -n "${LIB_PATH:-}" ] && [ -n "${HARNESS_PATH:-}" ] \
  || { echo "VENDORED_FROM must define REPO, SHA, LIB_PATH, HARNESS_PATH" >&2; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# fetch <path-in-cli> <dest>
fetch() {
  if [ -n "$CLI_DIR" ]; then
    git -C "$CLI_DIR" show "$SHA:$1" > "$2"
  else
    gh api -H 'Accept: application/vnd.github.raw' "repos/$REPO/contents/$1?ref=$SHA" > "$2"
  fi
}
# list_tree <dir-in-cli>: prints "mode path" for each file below it
list_tree() {
  if [ -n "$CLI_DIR" ]; then
    git -C "$CLI_DIR" ls-tree -r "$SHA" -- "$1" | awk '{print $1, $4}'
  else
    gh api "repos/$REPO/git/trees/$SHA?recursive=1" \
      --jq ".tree[] | select(.type==\"blob\" and (.path|startswith(\"$1/\"))) | \"\(.mode) \(.path)\""
  fi
}

fail=0
echo "vendored from $REPO @ $SHA"

# --- library ---
fetch "$LIB_PATH" "$TMP/lib.upstream"
LOCAL_LIB="$ROOT/templates/04_tn_k3s_ca_lib.sh"
EXPECT_HDR="# vendored from teknoir/cli $LIB_PATH @ $SHA"
if [ "$(sed -n 1p "$LOCAL_LIB")" != "$EXPECT_HDR" ]; then
  echo "DIFF: library header line 1 is not: $EXPECT_HDR" >&2; fail=1
fi
tail -n +2 "$LOCAL_LIB" > "$TMP/lib.local"
if cmp -s "$TMP/lib.local" "$TMP/lib.upstream"; then
  echo "ok:   templates/04_tn_k3s_ca_lib.sh is identical to cli $LIB_PATH at ${SHA:0:12}"
else
  echo "DIFF: templates/04_tn_k3s_ca_lib.sh differs from cli $LIB_PATH at ${SHA:0:12}" >&2
  diff -u "$TMP/lib.upstream" "$TMP/lib.local" | head -40 >&2 || true
  fail=1
fi

# --- harness ---
n=0
while read -r mode path; do
  [ -n "$path" ] || continue
  rel="${path#"$HARNESS_PATH"/}"
  fetch "$path" "$TMP/h.upstream"
  if [ ! -f "$HERE/$rel" ]; then
    echo "DIFF: missing $HARNESS_PATH/$rel" >&2; fail=1
  elif ! cmp -s "$HERE/$rel" "$TMP/h.upstream"; then
    echo "DIFF: $HARNESS_PATH/$rel differs from cli" >&2; fail=1
  elif [ "$mode" = 100755 ] && [ ! -x "$HERE/$rel" ]; then
    echo "DIFF: $HARNESS_PATH/$rel is not executable" >&2; fail=1
  fi
  n=$((n+1))
done < <(list_tree "$HARNESS_PATH")
[ "$n" -gt 0 ] || { echo "no files found under $HARNESS_PATH at $SHA" >&2; fail=1; }
[ "$fail" = 0 ] && echo "ok:   $n harness files identical to cli $HARNESS_PATH at ${SHA:0:12}"

if [ "$fail" = 0 ]; then echo "vendored files are identical to cli at ${SHA:0:12}"; else echo "vendored files DIFFER from cli at ${SHA:0:12}" >&2; exit 1; fi
