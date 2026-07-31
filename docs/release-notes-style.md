# Release notes style

Every GitHub Release in the mac-lucky fleet uses this format. The generator is
`.github/actions/generate-release-notes/notes.sh`; notes written by hand (or by
an agent asked for custom notes) must be indistinguishable from its output.

## Source material

Notes are built from the commits between the previous tag and the released tag,
merge commits excluded. The previous tag is the newest tag with the same prefix
(`v1.2.2` for `v1.2.3`; `relay/v1.0.0` for `relay/v1.0.1`). For monorepo
components, only commits touching the component's path are included.

Commits follow `type(scope): description` (scope optional). The type decides
the section; a `!` before the colon marks a breaking change.

## Format

- Sections, in this order, each a `## ` heading. Empty sections are omitted:
  1. `Breaking changes` - any type with `!`
  2. `Features` - feat
  3. `Fixes` - fix
  4. `Performance` - perf
  5. `Refactoring` - refactor
  6. `Documentation` - docs
  7. `Tests` - test
  8. `Maintenance` - chore, build, ci, deps
  9. `Other` - commits without a conventional prefix
- One bullet per commit: `- <scope>: <description> (<short sha>)`, or
  `- <description> (<short sha>)` when the commit has no scope. The type prefix
  is dropped; the section already says it.
- Descriptions keep the commit's own wording. Do not editorialize, group, or
  reword.
- Last line, after a blank line:
  `Full changelog: https://github.com/<owner>/<repo>/compare/<prev>...<tag>`
- ASCII punctuation only. No emoji, no em-dashes, no curly quotes.

## Special cases

- First release (no previous tag): the body is just `Initial release.` plus the
  changelog link pointing at `/commits/<tag>`.
- Rebuild tag with no commits in range (e.g. `v2.10.2-r1` re-releasing the same
  source): `Maintenance rebuild; no source changes since <prev>.` plus the
  changelog link.

## Example

```
## Features

- api: add retry with backoff to webhook delivery (a1b2c3d)

## Fixes

- config: reject empty listen address at startup (d4e5f6a)

## Maintenance

- deps: update golang.org/x/crypto to v0.55.0 (b7c8d9e)

Full changelog: https://github.com/mac-lucky/example/compare/v1.1.0...v1.2.0
```
