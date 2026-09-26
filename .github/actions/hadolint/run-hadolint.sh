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

case "$(uname -m)" in
  x86_64) bin=hadolint-linux-x86_64 ;;
  aarch64|arm64) bin=hadolint-linux-arm64 ;;
  *) echo "::error::no hadolint build for $(uname -m)"; exit 1 ;;
esac
dir="${RUNNER_TEMP:-/tmp}/hadolint"
base="https://github.com/hadolint/hadolint/releases/download/${HADOLINT_VERSION}"
mkdir -p "$dir"
for file in "$bin" checksums.sha256; do
  curl -sSfL --retry 3 --retry-all-errors --retry-max-time 60 --connect-timeout 10 --max-time 120 -o "$dir/$file" "$base/$file"
done
(cd "$dir" && grep " \*${bin}\$" checksums.sha256 | sha256sum -c -)
chmod +x "$dir/$bin"
"$dir/$bin" --version
"$dir/$bin" --failure-threshold error "$dockerfile"
