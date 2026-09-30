#!/usr/bin/env bash
# Lints one Dockerfile with the pinned hadolint release; only error-level
# findings fail, warnings and info are printed. Used by action.yml next to it
# and, fetched from master by raw URL, by the buildah-hadolint job in
# forgejo-shared-workflows. A .hadolint.yaml in the working directory is read
# as usual.
#
# Usage: run-hadolint.sh <dockerfile> [<build context>]
# The Dockerfile is looked up the way buildah does: as given, else inside the
# build context.
set -euo pipefail

# renovate: datasource=github-releases depName=hadolint/hadolint
HADOLINT_VERSION=v2.15.1

dockerfile=${1:?usage: run-hadolint.sh <dockerfile> [<build context>]}
[ -f "$dockerfile" ] || dockerfile="${2:-.}/$1"
[ -f "$dockerfile" ] || { echo "::error::Dockerfile not found: $1"; exit 1; }

# An image that ships this exact release (the Forgejo build lane's) skips the
# download. The pattern keeps 2.15.1 from matching 2.15.10.
version=${HADOLINT_VERSION#v}
if command -v hadolint > /dev/null \
  && hadolint --version 2> /dev/null | grep -Eq "(^|[^0-9.])v?${version//./\\.}([^0-9.]|\$)"; then
  cmd=$(command -v hadolint)
else
  case "$(uname -m)" in
    x86_64) bin=hadolint-linux-x86_64 ;;
    aarch64|arm64) bin=hadolint-linux-arm64 ;;
    *) echo "::error::no hadolint build for $(uname -m)"; exit 1 ;;
  esac
  base="https://github.com/hadolint/hadolint/releases/download/${HADOLINT_VERSION}"
  # --retry-max-time has to outlast --max-time, or a slow first attempt uses
  # up the budget and is never retried.
  get() { curl -sSfL --retry 3 --retry-all-errors --retry-max-time 300 --connect-timeout 10 --max-time 120 -o "$2" "$1"; }
  # The checksums always come from the release, never from the Actions cache
  # that action.yml restores the binary from.
  sums=$(mktemp)
  trap 'rm -f "$sums"' EXIT
  get "$base/checksums.sha256" "$sums"
  want=$(sed -n "s/^\([0-9a-f]\{64\}\) \*${bin}\$/\1/p" "$sums")
  [ -n "$want" ] || { echo "::error::no checksum for ${bin} in the ${HADOLINT_VERSION} release"; exit 1; }
  dir="${RUNNER_TEMP:-/tmp}/hadolint"
  cmd="$dir/$bin"
  verify() { [ -f "$cmd" ] && [ "$(sha256sum "$cmd" | cut -d' ' -f1)" = "$want" ]; }
  if ! verify; then
    mkdir -p "$dir"
    get "$base/$bin" "$cmd"
    verify || { echo "::error::${bin} does not match its release checksum"; exit 1; }
  fi
  chmod +x "$cmd"
fi
"$cmd" --version
"$cmd" --failure-threshold error "$dockerfile"
