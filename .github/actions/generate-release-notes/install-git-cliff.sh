#!/usr/bin/env bash
# Installs the pinned git-cliff (static musl build, checked against the
# .sha512 file published with the release) into the given directory, default
# $RUNNER_TEMP/git-cliff, and writes its path to the step output `path`. Used
# by action.yml, the release-notes fixture job in canary.yml, and, fetched
# from master by raw URL, buildah-build.yml in forgejo-shared-workflows.
set -euo pipefail

# renovate: datasource=github-releases depName=orhun/git-cliff extractVersion=^v(?<version>.*)$
GIT_CLIFF_VERSION=2.14.2

dir="${1:-${RUNNER_TEMP:?}/git-cliff}"
asset="git-cliff-${GIT_CLIFF_VERSION}-$(uname -m)-unknown-linux-musl.tar.gz"
base="https://github.com/orhun/git-cliff/releases/download/v${GIT_CLIFF_VERSION}"
mkdir -p "$dir"
cd "$dir"
# Retries: the release job runs after the images are published, and a
# transient github.com error here would fail it with nothing left to redo.
for file in "$asset" "$asset.sha512"; do
  curl -sSfLO --retry 3 --retry-all-errors --connect-timeout 10 --max-time 120 "${base}/${file}"
done
sha512sum -c "${asset}.sha512"
tar -xzf "$asset" --strip-components=1 "git-cliff-${GIT_CLIFF_VERSION}/git-cliff"
./git-cliff --version
echo "path=${PWD}/git-cliff" >> "${GITHUB_OUTPUT:-/dev/null}"
