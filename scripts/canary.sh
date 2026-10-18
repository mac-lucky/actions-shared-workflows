#!/usr/bin/env bash
# Caller canary for the analysis tool pins.
#
# The reusables pin golangci-lint, staticcheck, govulncheck, gosec and ruff as
# input defaults, and every caller inherits a new default the moment it merges.
# This script runs a changed pin against a real caller before that happens.
#
#   canary.sh pins <base-ref> <workflows-dir>
#       Prints "<tool> <old> <new>" for every pin that differs between
#       <base-ref> and the working tree. Prints nothing when none changed.
#
#   canary.sh run <caller-checkout> <pins-file>
#       For each changed pin listed in <pins-file> that is also in $TOOLS, runs
#       the new version over each module in $MODULES. A failure is only a
#       regression if the old version passes on the same tree: govulncheck
#       findings follow the vulnerability database, not the binary, and a
#       caller that is already red must not block an unrelated bump. ruff is
#       two gates, lint and format, as in python-cicd's matrix, and each one is
#       compared on its own.
#
# Environment for `run`:
#   TOOLS     space-separated subset of: staticcheck govulncheck gosec golangci-lint ruff
#   MODULES   space-separated module directories inside the caller (default ".");
#             for ruff, the build_context the caller passes to python-cicd
#
# ruff installs through uv, so a leg that runs it needs uv on PATH.
#
# The same file lives in actions-shared-workflows and forgejo-shared-workflows.
set -euo pipefail

pin_from() {
  # $1 = key (e.g. staticcheck_version), stdin = workflow file.
  # The default: line that follows the input key, quotes stripped. Same anchor
  # as the Renovate regex managers in default.json.
  awk -v key="$1:" '
    $1 == key { seen = 1; next }
    seen && $1 == "default:" { gsub(/["\047]/, "", $2); print $2; exit }
    seen && /^[[:space:]]*[a-z_]+:[[:space:]]*$/ { exit }
  '
}

env_pin_from() {
  # $1 = env name (e.g. GOVULNCHECK_VERSION), stdin = workflow file.
  awk -v key="$1:" '$1 == key { gsub(/["\047]/, "", $2); print $2; exit }'
}

cmd_pins() {
  local base="$1" dir="$2" tool key file old new
  while read -r tool key file; do
    [ -f "$dir/$file" ] || continue
    new="$(pin_from "$key" < "$dir/$file")"
    old="$(git show "$base:$dir/$file" 2>/dev/null | pin_from "$key" || true)"
    [ -n "$new" ] || { echo "no $key default in $dir/$file" >&2; exit 1; }
    if [ -n "$old" ] && [ "$old" != "$new" ]; then
      echo "$tool $old $new"
    fi
  done <<'EOF'
staticcheck staticcheck_version go-cicd-reusable.yml
govulncheck govulncheck_version go-cicd-reusable.yml
gosec gosec_version go-cicd-reusable.yml
golangci-lint golangci_lint_version golangci-lint-reusable.yml
ruff ruff_version python-cicd-reusable.yml
EOF
  # docker-cicd carries its own govulncheck pin as a workflow env.
  if [ -f "$dir/docker-cicd-reusable.yml" ]; then
    new="$(env_pin_from GOVULNCHECK_VERSION < "$dir/docker-cicd-reusable.yml")"
    old="$(git show "$base:$dir/docker-cicd-reusable.yml" 2>/dev/null | env_pin_from GOVULNCHECK_VERSION || true)"
    if [ -n "$old" ] && [ -n "$new" ] && [ "$old" != "$new" ]; then
      echo "govulncheck-binary $old $new"
    fi
  fi
}

install_tool() {
  # $1 = tool, $2 = version, $3 = target dir. Never the reusable's tool cache:
  # that is keyed per version and a warm entry would hide a broken install.
  local tool="$1" version="$2" dir="$3"
  mkdir -p "$dir"
  case "$tool" in
    staticcheck) GOBIN="$dir" go install "honnef.co/go/tools/cmd/staticcheck@$version" ;;
    govulncheck | govulncheck-binary) GOBIN="$dir" go install "golang.org/x/vuln/cmd/govulncheck@$version" ;;
    gosec) GOBIN="$dir" go install "github.com/securego/gosec/v2/cmd/gosec@$version" ;;
    golangci-lint)
      curl -sSfL "https://raw.githubusercontent.com/golangci/golangci-lint/$version/install.sh" \
        | sh -s -- -b "$dir" "$version" >/dev/null
      ;;
    ruff)
      # The reusables' install (uv tool install ruff==<version>), with its own
      # tool and bin dir so the old and the new version sit side by side.
      UV_TOOL_DIR="$dir/tools" UV_TOOL_BIN_DIR="$dir" uv tool install -q "ruff==$version"
      # Old against new means nothing if the binary is not the pin it was
      # installed for.
      local got
      got="$("$dir/ruff" --version)"
      [ "$got" = "ruff $version" ] || { echo "ruff==$version installed $got" >&2; exit 1; }
      ;;
    *) echo "unknown tool: $tool" >&2; exit 1 ;;
  esac
}

checks_of() {
  # $1 = tool. The gates one pin decides: ruff is two, so a format regression
  # is not hidden by a lint failure the old version shares.
  case "$1" in
    ruff) echo ruff-lint ruff-format ;;
    *) echo "$1" ;;
  esac
}

run_tool() {
  # $1 = check (see checks_of), $2 = bin dir. Runs in the current directory (a
  # module root) with the arguments the reusables pass.
  case "$1" in
    staticcheck) "$2/staticcheck" ./... ;;
    govulncheck) "$2/govulncheck" ./... ;;
    gosec) "$2/gosec" -fmt text ./... ;;
    golangci-lint) "$2/golangci-lint" run --timeout=10m ;;
    govulncheck-binary)
      # docker-cicd's use: reachability-scan a built binary into OpenVEX. That
      # path is fail-open in production, so an empty document is the failure.
      go build -o /tmp/canary-bin .
      "$2/govulncheck" -mode binary -format openvex /tmp/canary-bin > /tmp/canary.vex.json
      [ -s /tmp/canary.vex.json ]
      ;;
    ruff-lint) "$2/ruff" check . --output-format=concise ;;
    ruff-format) "$2/ruff" format --check . ;;
  esac
}

cmd_run() {
  local src="$1" pins="$2" tools=" ${TOOLS:-} " modules="${MODULES:-.}"
  local work tool old new module check regressions=0 ran=0
  # A missing module fails on both versions, which reads as "not caused by the
  # bump" and passes.
  for module in $modules; do
    [ -d "$src/$module" ] || { echo "::error::$module is not a directory in $src"; exit 1; }
  done
  work="$(mktemp -d)"
  while read -r tool old new; do
    [ -n "$tool" ] || continue
    case "$tools" in *" $tool "*) ;; *) continue ;; esac
    echo "::group::install $tool $old and $new"
    install_tool "$tool" "$new" "$work/new-$tool"
    install_tool "$tool" "$old" "$work/old-$tool"
    echo "::endgroup::"
    for module in $modules; do
      for check in $(checks_of "$tool"); do
        ran=$((ran + 1))
        echo "::group::$check $new in $module"
        if (cd "$src/$module" && run_tool "$check" "$work/new-$tool"); then
          echo "::endgroup::"
          echo "ok: $check $new passes in $module"
          continue
        fi
        echo "::endgroup::"
        echo "::group::$check $old in $module (baseline)"
        if (cd "$src/$module" && run_tool "$check" "$work/old-$tool"); then
          echo "::endgroup::"
          echo "::error::$check $new fails in $module where $old passes"
          regressions=$((regressions + 1))
        else
          echo "::endgroup::"
          echo "::warning::$check fails in $module on $old as well; not caused by the bump"
        fi
      done
    done
  done < "$pins"
  echo "canary: $ran run(s), $regressions regression(s)"
  [ "$regressions" -eq 0 ]
}

case "${1:-}" in
  pins) cmd_pins "$2" "$3" ;;
  run) cmd_run "$2" "$3" ;;
  *) echo "usage: canary.sh pins <base-ref> <workflows-dir> | run <caller-checkout> <pins-file>" >&2; exit 2 ;;
esac
