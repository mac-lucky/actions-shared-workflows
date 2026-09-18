#!/usr/bin/env bash
# Waive grype findings on packages that are already at their newest release.
#
# Usage: newest-release.sh <grype-json-report> [severity-cutoff]
#
# Prints a grype config holding one ignore rule per waived finding (or an
# empty `ignore: []`) on stdout; what it waived goes to stderr. Load it next to
# the normal policy with a second `-c` (scan-action: a second `config:` line).
#
# Why: an advisory can name a fix that no published version carries - a master
# pseudo-version, a pre-release, a release not cut yet. `--only-fixed` still
# counts that as fixable, so the gate fails with nothing to upgrade to. For
# each finding at or above the cutoff, the package's newest release is looked
# up in its registry (Go module proxy, npm, PyPI) and the finding is waived
# only when that newest release is the installed version. Anything that cannot
# be resolved stays gated: other ecosystems (apk, deb, binaries), the Go
# stdlib, lookup errors, and any installed version that is not exactly the
# registry's latest. Each rule is pinned to the installed version, so the next
# release puts the finding back in front of the gate.
#
# Needs bash, curl and jq. Used by the docker/go/node/python reusables here, by
# forgejo-shared-workflows' buildah-build and by forgejo-fleet-ops' scan-ghcr.
set -euo pipefail

report=${1:?usage: newest-release.sh <grype-json-report> [severity-cutoff]}
cutoff=${2:-high}

case "$(printf '%s' "$cutoff" | tr '[:upper:]' '[:lower:]')" in
  negligible) min=1 ;;
  low) min=2 ;;
  medium) min=3 ;;
  high) min=4 ;;
  critical) min=5 ;;
  *) echo "grype-newest-release: unknown severity cutoff '$cutoff'" >&2; exit 1 ;;
esac

# The newest release of one package, or nothing when it cannot be resolved.
latest_release() {
  local type=$1 name=$2 url
  case "$type" in
    go-module)
      # The stdlib is versioned by the toolchain, not the module proxy.
      [ "$name" = stdlib ] && return 0
      # Module proxy case-encoding: every capital becomes "!" + lowercase.
      url="https://proxy.golang.org/$(jq -rn --arg n "$name" '$n | gsub("(?<c>[A-Z])"; "!" + (.c | ascii_downcase))')/@latest"
      curl -sSfL --max-time 15 "$url" | jq -r '.Version // empty'
      ;;
    npm)
      curl -sSfL --max-time 15 "https://registry.npmjs.org/$(jq -rn --arg n "$name" '$n | sub("/"; "%2F")')/latest" \
        | jq -r '.version // empty'
      ;;
    python)
      curl -sSfL --max-time 15 "https://pypi.org/pypi/$name/json" | jq -r '.info.version // empty'
      ;;
  esac
}

# One line per distinct package with a gating finding: type, name, installed
# version, then each vulnerability id and its fix versions.
candidates=$(jq -r --argjson min "$min" '
  def rank: ascii_downcase | {negligible: 1, low: 2, medium: 3, high: 4, critical: 5}[.] // 0;
  [ .matches[]
    | select((.vulnerability.severity | rank) >= $min and .vulnerability.fix.state == "fixed")
    | { type: .artifact.type, name: .artifact.name, version: .artifact.version,
        vuln: "\(.vulnerability.id)=\(.vulnerability.fix.versions | join(","))" } ]
  | group_by([.type, .name, .version])[]
  | [.[0].type, .[0].name, .[0].version, (map(.vuln) | unique | join(" "))]
  | @tsv' "$report")

rules=()
while IFS=$'\t' read -r type name version vulns; do
  [ -n "$name" ] || continue
  latest=$(latest_release "$type" "$name" 2>/dev/null || true)
  if [ -z "$latest" ] || [ "$latest" != "$version" ]; then
    continue
  fi
  for entry in $vulns; do
    id=${entry%%=*}
    fix=${entry#*=}
    echo "::warning::grype waiver: $id in $name $version - that is the newest release on the registry and the advisory's fix ($fix) is in no published version" >&2
    rules+=("$(jq -n --arg id "$id" --arg name "$name" --arg version "$version" --arg type "$type" \
      --arg reason "newest release on the registry; fix $fix is unreleased" \
      '{vulnerability: $id, reason: $reason, package: {name: $name, version: $version, type: $type}}')")
  done
done <<< "$candidates"

if [ "${#rules[@]}" -eq 0 ]; then
  echo "grype-newest-release: nothing to waive" >&2
  printf 'ignore: []\n'
  exit 0
fi
# JSON is valid YAML, and jq does the quoting.
printf '%s\n' "${rules[@]}" | jq -s '{ignore: .}'
