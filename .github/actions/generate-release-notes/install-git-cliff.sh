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
mkdir -p "$dir"
cd "$dir"
# An image that ships this exact release (the Forgejo build lane's) skips the
# download; the link keeps <dir>/git-cliff the path every caller runs. The
# pattern keeps 2.14.2 from matching 2.14.20.
if command -v git-cliff > /dev/null \
  && git-cliff --version 2> /dev/null | grep -Eq "(^|[^0-9.])v?${GIT_CLIFF_VERSION//./\\.}([^0-9.]|\$)"; then
  ln -sf "$(command -v git-cliff)" git-cliff
else
  asset="git-cliff-${GIT_CLIFF_VERSION}-$(uname -m)-unknown-linux-musl.tar.gz"
  base="https://github.com/orhun/git-cliff/releases/download/v${GIT_CLIFF_VERSION}"
  # Retries: the release job runs after the images are published, and a
  # transient github.com error here would fail it with nothing left to redo.
  # --retry-max-time has to outlast --max-time, or a slow first attempt uses
  # up the budget and is never retried.
  for file in "$asset" "$asset.sha512"; do
    curl -sSfLO --retry 3 --retry-all-errors --retry-max-time 300 --connect-timeout 10 --max-time 120 "${base}/${file}"
  done
  sha512sum -c "${asset}.sha512"
  rm -f git-cliff
  tar -xzf "$asset" --strip-components=1 "git-cliff-${GIT_CLIFF_VERSION}/git-cliff"
fi
./git-cliff --version
echo "path=${PWD}/git-cliff" >> "${GITHUB_OUTPUT:-/dev/null}"
