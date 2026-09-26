#!/usr/bin/env bash
# Build grouped release notes from conventional commits. The format lives in
# docs/release-notes-style.md - keep the two in sync. The sections are rendered
# by git-cliff with cliff.toml next to this script; this script picks the
# range, handles the first-release and empty-range cases and adds the
# changelog link. Needs a full-history checkout (fetch-depth: 0); a shallow
# clone cannot see the previous tag.
#
# Env: TAG (required), PATH_FILTER, OUTPUT_FILE, GIT_CLIFF, CLIFF_CONFIG, and
# for the changelog link CHANGELOG_BASE_URL (default
# https://github.com/$GITHUB_REPOSITORY; no link when neither is set) and
# FIRST_RELEASE_PATH (default `commits`; Forgejo's tag view is `commits/tag`).
set -euo pipefail

TAG="${TAG:?TAG is required}"
PATH_FILTER="${PATH_FILTER:-}"
OUTPUT_FILE="${OUTPUT_FILE:-release-notes.md}"
GIT_CLIFF="${GIT_CLIFF:-git-cliff}"
CLIFF_CONFIG="${CLIFF_CONFIG:-$(dirname "${BASH_SOURCE[0]}")/cliff.toml}"
BASE_URL="${CHANGELOG_BASE_URL:-${GITHUB_REPOSITORY:+https://github.com/$GITHUB_REPOSITORY}}"
FIRST_RELEASE_PATH="${FIRST_RELEASE_PATH:-commits}"

# Tags are plain (v1.2.3) or prefixed (relay/v1.2.3). The previous tag is the
# nearest same-prefix ancestor of the released commit - NOT the highest-sorting
# tag: repos that carry legacy tags numbered above the new release line (e.g.
# pushward-server's vX.Y.Z-bN app-build markers) would otherwise get a wrong
# range forever. Fall back to the version sort only when ancestry finds nothing
# (e.g. the tag sits on a rewritten branch).
PREFIX=""
if [[ "$TAG" == */* ]]; then
  PREFIX="${TAG%/*}/"
fi

PREV=$(git describe --tags --abbrev=0 --match "${PREFIX}v*" --exclude "$TAG" "${TAG}^" 2>/dev/null || true)
if [ -z "$PREV" ]; then
  PREV=$(git tag --list "${PREFIX}v*" --sort=-version:refname | grep -Fxv "$TAG" | head -n1 || true)
fi
{
  echo "previous_tag=${PREV}"
} >> "${GITHUB_OUTPUT:-/dev/null}"

# The last line, after a blank one: `changelog <path below the repo URL>`.
changelog() {
  if [ -n "$BASE_URL" ]; then
    printf '\nFull changelog: %s/%s\n' "${BASE_URL%/}" "$1" >> "$OUTPUT_FILE"
  fi
}

: > "$OUTPUT_FILE"

# First release: listing the entire history helps nobody.
if [ -z "$PREV" ]; then
  echo "Initial release." >> "$OUTPUT_FILE"
  changelog "${FIRST_RELEASE_PATH}/${TAG}"
  exit 0
fi

# The filter is space-separated directories or files relative to the repo
# root, e.g. "./relay ./shared" for a monorepo component plus the module it
# embeds. git-cliff takes globs, so each entry becomes the path itself and
# everything below it. Pathspec magic and wildcards would change meaning in
# that translation and are refused.
include=()
if [ -n "$PATH_FILTER" ]; then
  read -ra paths <<< "$PATH_FILTER"
  for p in "${paths[@]}"; do
    case "$p" in
      :*|*[*?[]*) echo "::error::path_filter entry '$p': only plain paths are supported" >&2; exit 1 ;;
    esac
    p="${p#./}"
    p="${p%/}"
    case "$p" in
      ""|.) include=(); break ;;
    esac
    include+=(--include-path "$p" --include-path "$p/**")
  done
fi

# git-cliff prints full hashes; the notes show git log's %h abbreviation.
SECTIONS=$("$GIT_CLIFF" --no-exec --config "$CLIFF_CONFIG" ${include[@]+"${include[@]}"} "${PREV}..${TAG}" \
  | sed -f <(git log --format='s/(%H)$/(%h)/' "${PREV}..${TAG}"))

if [ -z "$SECTIONS" ]; then
  echo "Maintenance rebuild; no source changes since ${PREV}." >> "$OUTPUT_FILE"
else
  printf '%s\n' "$SECTIONS" >> "$OUTPUT_FILE"
fi
changelog "compare/${PREV}...${TAG}"

echo "Notes for ${TAG} (since ${PREV}):"
cat "$OUTPUT_FILE"
