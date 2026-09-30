#!/usr/bin/env bash
# Loads the Grype DB from the LAN copy that forgejo-fleet-ops' scan-ghcr
# publishes nightly, so Forgejo builds stop downloading it from Anchore.
# Fetched from master by raw URL; never fails the job.
#
# The copy is the Forgejo generic package mac-lucky/grype-db-v6, one version
# per UTC publication date (YYYY-MM-DD), holding:
#   db.tar.zst  zstd tar of the contents of a hydrated $GRYPE_DB_CACHE_DIR/6
#   meta.json   {"version","built","schema","grype","sha256"}, uploaded last,
#               sha256 being that of db.tar.zst
# Today's version is tried first, then yesterday's. A DB that loads and is at
# most 48h old sets GRYPE_DB_AUTO_UPDATE=false for the rest of the job; on any
# failure this warns and runs `grype db update` instead, and if that fails too
# the scan downloads the DB itself.
#
# Env: FORGEJO_TOKEN (package read; the job token will do), GRYPE_DB_CACHE_DIR
# (default /tmp/grype-db), FORGEJO_URL (default https://git.maclucky.win).
# Writes GRYPE_DB_CACHE_DIR (and GRYPE_DB_AUTO_UPDATE) to $GITHUB_ENV when
# set, else prints them.
# Needs grype, curl, zstd, tar, sha256sum and jq.
set -uo pipefail

export GRYPE_DB_CACHE_DIR="${GRYPE_DB_CACHE_DIR:-/tmp/grype-db}"
forgejo="${FORGEJO_URL:-https://git.maclucky.win}"
forgejo="${forgejo%/}"
base="$forgejo/api/packages/mac-lucky/generic/grype-db-v6"

emit() {
  if [ -n "${GITHUB_ENV:-}" ]; then
    printf '%s\n' "$@" >> "$GITHUB_ENV"
  else
    printf '%s\n' "$@"
  fi
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The token goes into a netrc, never onto a command line or into the log.
auth=()
if [ -n "${FORGEJO_TOKEN:-}" ]; then
  host="${forgejo#*://}"
  host="${host%%/*}"
  host="${host%%:*}"
  (umask 077 && printf 'machine %s login token password %s\n' "$host" "$FORGEJO_TOKEN" > "$work/netrc")
  auth=(--netrc-file "$work/netrc")
fi

# Plain --retry: a 404 (no package for that date yet) is an answer, not a
# transient error worth retrying. --retry-max-time has to outlast
# --max-time, or a slow first attempt uses up the budget and is never retried.
fetch() {
  curl -sSfL ${auth[@]+"${auth[@]}"} --retry 3 --retry-max-time 900 \
    --connect-timeout 10 --max-time 300 -o "$2" "$1"
}

# Downloads, verifies and unpacks one version into $GRYPE_DB_CACHE_DIR/6.
load() {
  local version=$1 want got
  fetch "$base/$version/meta.json" "$work/meta.json" || return 1
  want=$(jq -er --arg v "$version" 'select(.version == $v) | .sha256' "$work/meta.json") || {
    echo "meta.json of $version is malformed"
    return 1
  }
  [[ $want =~ ^[0-9a-f]{64}$ ]] || { echo "meta.json of $version has no valid sha256"; return 1; }
  fetch "$base/$version/db.tar.zst" "$work/db.tar.zst" || return 1
  got=$(sha256sum "$work/db.tar.zst" | cut -d' ' -f1)
  [ "$got" = "$want" ] || { echo "db.tar.zst of $version: sha256 $got, meta.json says $want"; return 1; }
  rm -rf "$work/6"
  mkdir "$work/6" || return 1
  zstd -dcq "$work/db.tar.zst" | tar -xf - --no-same-owner -C "$work/6" || return 1
  rm -f "$work/db.tar.zst"
  mkdir -p "$GRYPE_DB_CACHE_DIR" || return 1
  rm -rf "$GRYPE_DB_CACHE_DIR/6"
  mv "$work/6" "$GRYPE_DB_CACHE_DIR/6" || return 1
  echo "Loaded Grype DB $version from $forgejo: $(jq -c '{built, schema, grype}' "$work/meta.json")"
}

today=$(date -u +%F)
yesterday=$(date -u -d yesterday +%F 2> /dev/null || date -u -v-1d +%F)
for version in "$today" "$yesterday"; do
  if load "$version" && GRYPE_DB_MAX_ALLOWED_BUILT_AGE=48h grype db status; then
    emit "GRYPE_DB_CACHE_DIR=$GRYPE_DB_CACHE_DIR" "GRYPE_DB_AUTO_UPDATE=false"
    exit 0
  fi
done

# Start the fallback from nothing, so it never keeps the DB just rejected.
echo "::warning::no usable Grype DB in the $base package; downloading it from Anchore"
rm -rf "$GRYPE_DB_CACHE_DIR/6"
if grype db update; then
  emit "GRYPE_DB_CACHE_DIR=$GRYPE_DB_CACHE_DIR"
else
  echo "::warning::grype db update failed; the scan will try again"
fi
exit 0
