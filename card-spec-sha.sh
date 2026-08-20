#!/usr/bin/env bash
# card-spec-sha.sh -- turn a GitHub file link into a commit-pinned specs[] entry for a Pocket card.
#
# Resolves the branch ref to the commit that last touched the file, fetches the raw bytes
# GitHub actually serves at that pinned URL, and prints the sha256 of exactly those bytes.
#
# Usage:
#   ./card-spec-sha.sh <github-url> [--kind <kind>] [--ref <branch|tag|sha>]
#
# Accepts blob, /raw/ and raw.githubusercontent.com URLs; ?plain=1 and #L10 are stripped.
#
# Examples:
#   ./card-spec-sha.sh https://github.com/my-org/my-repo/blob/main/services/text-generation/CONNECTION.md
#   ./card-spec-sha.sh https://raw.githubusercontent.com/my-org/my-repo/main/openapi.json --kind openapi
#   ./card-spec-sha.sh <url> | jq .          # pipe the snippet
#   ./card-spec-sha.sh <url> | pbcopy        # straight to clipboard

set -euo pipefail

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }   # progress goes to stderr so stdout stays pure JSON

KIND="markdown"
REF_OVERRIDE=""
URL=""

while [ $# -gt 0 ]; do
  case "$1" in
    --kind) KIND="${2:?--kind needs a value}"; shift 2 ;;
    --ref)  REF_OVERRIDE="${2:?--ref needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown flag: $1" ;;
    *)  [ -z "$URL" ] || die "only one URL accepted"; URL="$1"; shift ;;
  esac
done
[ -n "$URL" ] || die "no URL given (try --help)"

# --- sha256, portably (macOS shasum / GNU sha256sum)
if command -v shasum >/dev/null 2>&1; then
  sha256() { shasum -a 256 | awk '{print $1}'; }
elif command -v sha256sum >/dev/null 2>&1; then
  sha256() { sha256sum | awk '{print $1}'; }
else
  die "need shasum or sha256sum on PATH"
fi

# --- parse the URL into org / repo / ref / path
URL="${URL%%#*}"          # drop #L10 line anchors
URL="${URL%%\?*}"         # drop ?plain=1

if [[ "$URL" =~ ^https?://github\.com/([^/]+)/([^/]+)/(blob|raw)/(.+)$ ]]; then
  ORG="${BASH_REMATCH[1]}"; REPO="${BASH_REMATCH[2]}"; REST="${BASH_REMATCH[4]}"
elif [[ "$URL" =~ ^https?://raw\.githubusercontent\.com/([^/]+)/([^/]+)/(.+)$ ]]; then
  ORG="${BASH_REMATCH[1]}"; REPO="${BASH_REMATCH[2]}"; REST="${BASH_REMATCH[3]}"
else
  die "not a recognised GitHub file URL: $URL"
fi

REST="${REST#refs/heads/}"                 # raw URLs sometimes carry refs/heads/main
REF="${REST%%/*}"; FILE_PATH="${REST#*/}"
[ "$REF" != "$FILE_PATH" ] || die "could not split ref from path in: $REST"
[ -z "$REF_OVERRIDE" ] || REF="$REF_OVERRIDE"

# --- resolve ref -> commit SHA (the commit that last touched THIS path, not the branch head,
#     so an unrelated push to the branch does not invalidate a pin that is still accurate)
if [[ "$REF" =~ ^[0-9a-f]{40}$ ]]; then
  COMMIT="$REF"
  note "ref is already a full commit SHA"
else
  note "resolving $ORG/$REPO@$REF -- last commit touching $FILE_PATH ..."
  API="repos/$ORG/$REPO/commits?path=$FILE_PATH&sha=$REF&per_page=1"
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    COMMIT="$(gh api "$API" --jq '.[0].sha' 2>/dev/null || true)"
  else
    RESP="$(curl -fsSL -H 'Accept: application/vnd.github+json' "https://api.github.com/$API" || true)"
    if command -v jq >/dev/null 2>&1; then
      COMMIT="$(printf '%s' "$RESP" | jq -r '.[0].sha // empty' 2>/dev/null || true)"
    else
      COMMIT="$(printf '%s' "$RESP" | python3 -c \
        'import json,sys; d=json.load(sys.stdin); print(d[0]["sha"] if d else "")' 2>/dev/null || true)"
    fi
  fi
  [ -n "$COMMIT" ] && [ "$COMMIT" != "null" ] \
    || die "could not resolve a commit for $ORG/$REPO@$REF path=$FILE_PATH (private repo? wrong path? rate limited? try: gh auth login)"
fi

[[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "resolved commit is not 40 hex chars: $COMMIT"

RAW="https://raw.githubusercontent.com/$ORG/$REPO/$COMMIT/$FILE_PATH"

# --- hash the bytes GitHub actually serves. -f so a 404 page is never hashed by mistake.
note "fetching $RAW"
BODY="$(mktemp)"; trap 'rm -f "$BODY"' EXIT
curl -fsSL "$RAW" -o "$BODY" \
  || die "fetch failed -- commit not pushed yet, path wrong, or repo private"

BYTES="$(wc -c < "$BODY" | tr -d ' ')"
[ "$BYTES" -gt 0 ] || die "served document is empty"

DIGEST="$(sha256 < "$BODY")"
[[ "$DIGEST" =~ ^[0-9a-f]{64}$ ]] || die "digest is not 64 lowercase hex: $DIGEST"

note "commit: $COMMIT"
note "bytes : $BYTES"
note ""

cat <<JSON
{
  "kind": "$KIND",
  "url": "$RAW",
  "sha256": "$DIGEST"
}
JSON
