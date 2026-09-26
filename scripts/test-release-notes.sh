#!/usr/bin/env bash
# Fixture test for .github/actions/generate-release-notes. Builds a throwaway
# repo with fixed identities and dates, so every hash below is stable, runs
# notes.sh for each tag and compares the output byte for byte. Needs git-cliff
# on PATH (or GIT_CLIFF pointing at it). canary.yml runs it on every PR.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
notes="$root/.github/actions/generate-release-notes/notes.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.com
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.com
export GITHUB_REPOSITORY=mac-lucky/fixture
unset GITHUB_OUTPUT
t=1767225600

stamp() {
  t=$((t + 60))
  export GIT_AUTHOR_DATE="@$t +0000" GIT_COMMITTER_DATE="@$t +0000"
}

# commit <file> <message> [<message>...]: each extra message is a paragraph.
commit() {
  local file=$1
  shift
  stamp
  mkdir -p "$(dirname "$file")"
  echo "$t" >> "$file"
  git add "$file"
  local args=()
  for m in "$@"; do args+=(-m "$m"); done
  git commit -q "${args[@]}"
}

tag() {
  stamp
  git tag -a "$1" -m "$1"
}

# check <name> <tag> <path filter> <expected>. The link settings come from
# base_url and first_path; empty means notes.sh's GitHub defaults.
fail=0
base_url=""
first_path=""
check() {
  local name=$1 tag=$2 filter=$3 expected=$4 actual
  actual=$(TAG="$tag" PATH_FILTER="$filter" OUTPUT_FILE="$work/notes.md" \
    CHANGELOG_BASE_URL="$base_url" FIRST_RELEASE_PATH="$first_path" \
    bash "$notes" > /dev/null && cat "$work/notes.md"; echo x)
  actual=${actual%x}
  if [ "$actual" == "$expected" ]; then
    echo "ok   $name"
  else
    echo "FAIL $name"
    diff <(printf '%s' "$expected") <(printf '%s' "$actual") || true
    fail=1
  fi
}

cd "$work"
git init -q -b main .

commit README.md "Initial commit"
tag v1.0.0

check "first release" v1.0.0 "" "Initial release.

Full changelog: https://github.com/mac-lucky/fixture/commits/v1.0.0
"

# How buildah-build calls it on Forgejo: the forge's URL, its tag view.
base_url=https://git.example.com/mac-lucky/fixture/
first_path=commits/tag
check "first release, Forgejo links" v1.0.0 "" "Initial release.

Full changelog: https://git.example.com/mac-lucky/fixture/commits/tag/v1.0.0
"
base_url=""
first_path=""

commit api/a.go "feat(api): add webhook retries"
commit api/b.go "feat: support \$HOME and \`backticks\` in paths"
commit api/c.go "fix(config): reject an empty listen address"
commit api/d.go "fix: handle nil pointer"
commit api/e.go "perf(db): batch inserts"
commit api/f.go "refactor: split handler"
commit README.md "docs: explain setup"
commit api/g.go "test(api): cover retries"
commit go.mod "chore(deps): update golang.org/x/crypto to v0.55.0"
commit Dockerfile "build: pin the base image"
commit ci.yml "ci: cache modules"
commit go.sum "deps: bump everything"
commit api/h.go "feat(api)!: drop the v1 endpoints"
commit api/i.go "fix!: change the default port"
commit api/j.go "feat(api): stream events" "BREAKING CHANGE: footers do not make a breaking change here"
commit api/k.go "feat(): empty scope"
commit api/l.go "Feat: uppercase type"
commit api/m.go "feat : space before colon"
commit api/n.go "Update README.md"
commit api/o.go "$(printf 'feat(api): a subject that wraps\nonto a second line')" "Body paragraph."

git checkout -q -b topic
commit api/p.go "fix(api): fix on a branch"
# A marker tag numbered above the release line, off the release ancestry:
# the previous tag is the nearest ancestor, not the highest version.
git checkout -q -b marker
commit app/build.txt "chore: app build"
tag v9.0.0-b1
git checkout -q main
commit api/q.go "chore: tidy"
stamp
git merge -q --no-ff topic -m "Merge branch 'topic'"
tag v1.1.0

# Monorepo component: relay/ plus the shared/ module it embeds.
commit relay/main.go "feat(relay): first cut"
tag relay/v1.0.0
commit relay/main.go "fix(relay): reconnect on close"
commit shared/log.go "feat(shared): structured logging"
commit sabnzbd/main.go "feat(sabnzbd): first cut"
tag sabnzbd/v0.1.0
commit other/x.go "chore(other): unrelated"
commit relay/sub/deep.go "refactor(relay): move the client"
tag relay/v1.1.0
commit other/y.go "chore(other): still unrelated"
tag relay/v1.1.1

check "every section" v1.1.0 "" '## Breaking changes

- change the default port (819e63b)
- api: drop the v1 endpoints (f6b7ce2)

## Features

- api: a subject that wraps onto a second line (7fa02f1)
- empty scope (6f52793)
- api: stream events (62ecab3)
- support $HOME and `backticks` in paths (eb5c17b)
- api: add webhook retries (e03cb9b)

## Fixes

- api: fix on a branch (26db229)
- handle nil pointer (a84ba6c)
- config: reject an empty listen address (557a87c)

## Performance

- db: batch inserts (4a8c405)

## Refactoring

- split handler (0081974)

## Documentation

- explain setup (e2be9fc)

## Tests

- api: cover retries (99dbfce)

## Maintenance

- tidy (d675575)
- bump everything (1595b38)
- cache modules (af6e0eb)
- pin the base image (623cfa8)
- deps: update golang.org/x/crypto to v0.55.0 (97f8b09)

## Other

- Update README.md (156cee9)
- feat : space before colon (476a6a4)
- Feat: uppercase type (c3ddd25)

Full changelog: https://github.com/mac-lucky/fixture/compare/v1.0.0...v1.1.0
'

check "prefixed tag with path filter" relay/v1.1.0 "./relay shared/" '## Features

- shared: structured logging (01d2b77)

## Fixes

- relay: reconnect on close (03056bb)

## Refactoring

- relay: move the client (42c9cbf)

Full changelog: https://github.com/mac-lucky/fixture/compare/relay/v1.0.0...relay/v1.1.0
'

check "nothing in range" relay/v1.1.1 "./relay ./shared" "Maintenance rebuild; no source changes since relay/v1.1.0.

Full changelog: https://github.com/mac-lucky/fixture/compare/relay/v1.1.0...relay/v1.1.1
"

base_url=https://git.example.com/mac-lucky/fixture
first_path=commits/tag
check "nothing in range, Forgejo links" relay/v1.1.1 "./relay ./shared" "Maintenance rebuild; no source changes since relay/v1.1.0.

Full changelog: https://git.example.com/mac-lucky/fixture/compare/relay/v1.1.0...relay/v1.1.1
"
base_url=""
first_path=""

# A glob would mean something else to git-cliff than to git log.
if TAG=relay/v1.1.0 PATH_FILTER="./relay/*.go" OUTPUT_FILE="$work/notes.md" bash "$notes" > /dev/null 2>&1; then
  echo "FAIL glob path filter accepted"
  fail=1
else
  echo "ok   glob path filter refused"
fi

exit "$fail"
