#!/usr/bin/env bash
# Build grouped release notes from conventional commits. The format lives in
# docs/release-notes-style.md - keep the two in sync. Needs a full-history
# checkout (fetch-depth: 0); a shallow clone cannot see the previous tag.
set -euo pipefail

TAG="${TAG:?TAG is required}"
PATH_FILTER="${PATH_FILTER:-}"
OUTPUT_FILE="${OUTPUT_FILE:-release-notes.md}"
REPO="${GITHUB_REPOSITORY:-}"

# Tags are plain (v1.2.3) or prefixed (relay/v1.2.3). The previous tag is the
# newest tag sharing the prefix, excluding the one being released. Rebuild tags
# (v1.2.3-r1) sort after their base under version sort, which is what we want:
# the range for v1.2.3-r2 starts at v1.2.3-r1.
PREFIX=""
if [[ "$TAG" == */* ]]; then
  PREFIX="${TAG%/*}/"
fi

PREV=$(git tag --list "${PREFIX}v*" --sort=-version:refname | grep -Fxv "$TAG" | head -n1 || true)
{
  echo "previous_tag=${PREV}"
} >> "${GITHUB_OUTPUT:-/dev/null}"

: > "$OUTPUT_FILE"

# First release: listing the entire history helps nobody.
if [ -z "$PREV" ]; then
  echo "Initial release." >> "$OUTPUT_FILE"
  if [ -n "$REPO" ]; then
    printf '\nFull changelog: https://github.com/%s/commits/%s\n' "$REPO" "$TAG" >> "$OUTPUT_FILE"
  fi
  exit 0
fi

git_log() {
  if [ -n "$PATH_FILTER" ]; then
    git log --no-merges --format='%h %s' "${PREV}..${TAG}" -- "$PATH_FILTER"
  else
    git log --no-merges --format='%h %s' "${PREV}..${TAG}"
  fi
}
COMMITS=$(git_log)

if [ -z "$COMMITS" ]; then
  echo "Maintenance rebuild; no source changes since ${PREV}." >> "$OUTPUT_FILE"
  if [ -n "$REPO" ]; then
    printf '\nFull changelog: https://github.com/%s/compare/%s...%s\n' "$REPO" "$PREV" "$TAG" >> "$OUTPUT_FILE"
  fi
  exit 0
fi

# Track which commits landed in a section so Other can pick up the rest.
MATCHED_FILE=$(mktemp)
trap 'rm -f "$MATCHED_FILE"' EXIT

emit_line() {
  local line="$1" sha subject rest typepart scope
  sha="${line%% *}"
  subject="${line#* }"
  rest="${subject#*: }"
  typepart="${subject%%:*}"
  scope=""
  if [[ "$typepart" == *"("*")"* ]]; then
    scope="${typepart#*(}"
    scope="${scope%%)*}"
  fi
  if [ -n "$scope" ]; then
    printf -- '- %s: %s (%s)\n' "$scope" "$rest" "$sha" >> "$OUTPUT_FILE"
  else
    printf -- '- %s (%s)\n' "$rest" "$sha" >> "$OUTPUT_FILE"
  fi
  echo "$sha" >> "$MATCHED_FILE"
}

section() {
  local title="$1" pattern="$2" body line
  body=$(printf '%s\n' "$COMMITS" | grep -E "$pattern" || true)
  [ -z "$body" ] && return 0
  printf '## %s\n\n' "$title" >> "$OUTPUT_FILE"
  while IFS= read -r line; do
    emit_line "$line"
  done <<< "$body"
  printf '\n' >> "$OUTPUT_FILE"
}

# A '!' before the colon marks a breaking change and wins over the type
# section; the type patterns below require the colon directly after the type
# or scope, so a breaking commit cannot appear twice.
section 'Breaking changes' '^[0-9a-f]+ [a-z]+(\([^)]*\))?!: '
section 'Features'         '^[0-9a-f]+ feat(\([^)]*\))?: '
section 'Fixes'            '^[0-9a-f]+ fix(\([^)]*\))?: '
section 'Performance'      '^[0-9a-f]+ perf(\([^)]*\))?: '
section 'Refactoring'      '^[0-9a-f]+ refactor(\([^)]*\))?: '
section 'Documentation'    '^[0-9a-f]+ docs(\([^)]*\))?: '
section 'Tests'            '^[0-9a-f]+ test(\([^)]*\))?: '
section 'Maintenance'      '^[0-9a-f]+ (chore|build|ci|deps)(\([^)]*\))?: '

# Anything that did not land above (non-conventional subjects).
OTHER=""
while IFS= read -r line; do
  sha="${line%% *}"
  if ! grep -qFx "$sha" "$MATCHED_FILE"; then
    OTHER+="${line}"$'\n'
  fi
done <<< "$COMMITS"
if [ -n "$OTHER" ]; then
  printf '## Other\n\n' >> "$OUTPUT_FILE"
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    sha="${line%% *}"
    subject="${line#* }"
    printf -- '- %s (%s)\n' "$subject" "$sha" >> "$OUTPUT_FILE"
  done <<< "$OTHER"
  printf '\n' >> "$OUTPUT_FILE"
fi

printf 'Full changelog: https://github.com/%s/compare/%s...%s\n' "$REPO" "$PREV" "$TAG" >> "$OUTPUT_FILE"

echo "Notes for ${TAG} (since ${PREV}):"
cat "$OUTPUT_FILE"
