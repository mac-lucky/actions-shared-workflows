#!/usr/bin/env bash
# Grype gate that waives findings on packages already at their newest release.
#
# Usage: grype-newest-release.sh <grype-json-report> [severity-cutoff]
#
# Reads the JSON report of a scan that failed the gate (same config, same
# --only-fixed) and exits 2 when a finding at or above the cutoff is left after
# the waivers, 0 when none is. Any other exit is an error; callers treat every
# non-zero exit as a failed gate.
#
# Why: an advisory can name a fix that no published version carries - a master
# pseudo-version, a pre-release, a release not cut yet. `--only-fixed` still
# counts that as fixable, so the gate fails with nothing to upgrade to. A
# package's findings are waived only when all of them have a fix and the
# installed version is exactly the newest release in its registry (Go module
# proxy, npm, PyPI). Everything else stays gated: other ecosystems (apk, deb,
# binaries), the Go stdlib, lookup errors. The package's next release puts its
# findings back in front of the gate.
#
# Callers: the grype-newest-release action here (docker/go/node/python
# reusables), forgejo-shared-workflows' buildah-build and forgejo-fleet-ops'
# scan-ghcr, the last two by raw URL from master. Needs bash, curl and jq.
set -euo pipefail

report=${1:?usage: grype-newest-release.sh <grype-json-report> [severity-cutoff]}
cutoff=${2:-high}

# The newest release of one package, or nothing when it cannot be resolved.
latest_release() {
  local type=$1 name=$2 url field
  case "$type" in
    go-module)
      # The stdlib is versioned by the toolchain, not the module proxy.
      [ "$name" = stdlib ] && return 0
      # Module proxy case-encoding: every capital becomes "!" + lowercase.
      url="https://proxy.golang.org/$(jq -rn --arg n "$name" '$n | gsub("(?<c>[A-Z])"; "!" + (.c | ascii_downcase))')/@latest"
      field=.Version ;;
    npm)
      url="https://registry.npmjs.org/$(jq -rn --arg n "$name" '$n | @uri')/latest"
      field=.version ;;
    python)
      url="https://pypi.org/pypi/$name/json"
      field=.info.version ;;
    *) return 0 ;;
  esac
  curl -sSfL --max-time 15 "$url" | jq -r "$field // empty"
}

# One line per package with a finding at or above the cutoff: type, name,
# installed version, whether every such finding has a fix, and the findings.
packages=$(jq -r --arg cutoff "$cutoff" '
  def rank: ascii_downcase | {negligible: 1, low: 2, medium: 3, high: 4, critical: 5}[.] // 0;
  ($cutoff | rank) as $min
  | if $min == 0 then error("unknown severity cutoff: \($cutoff)") else . end
  | [ .matches[] | select((.vulnerability.severity | rank) >= $min) ]
  | group_by([.artifact.type, .artifact.name, .artifact.version])[]
  | [ .[0].artifact.type, .[0].artifact.name, .[0].artifact.version,
      all(.vulnerability.fix.state == "fixed"),
      (map("\(.vulnerability.id) (fix \(.vulnerability.fix.versions | join(", ")))") | unique | join("; ")) ]
  | @tsv' "$report")

left=0
while IFS=$'\t' read -r type name version fixed findings; do
  [ -n "$name" ] || continue
  if [ "$fixed" = true ] && [ "$(latest_release "$type" "$name" 2>/dev/null || true)" = "$version" ]; then
    echo "::warning::grype waiver: $name $version is the newest release, nothing to upgrade to: $findings"
  else
    echo "gating: $type $name $version: $findings"
    left=$((left + 1))
  fi
done <<< "$packages"

[ "$left" -eq 0 ] || { echo "$left package(s) with findings at or above $cutoff and a newer release to move to"; exit 2; }
