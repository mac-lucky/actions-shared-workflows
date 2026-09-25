#!/usr/bin/env bash
# Installs the pinned git-cliff (static musl build, checked against the
# .sha512 file published with the release) into $RUNNER_TEMP/git-cliff and
# writes its path to the step output `path`. Used by action.yml and by the
# release-notes fixture job in canary.yml. buildah-build.yml in
# forgejo-shared-workflows pins the same version on its own.
set -euo pipefail

# renovate: datasource=github-releases depName=orhun/git-cliff extractVersion=^v(?<version>.*)$
GIT_CLIFF_VERSION=2.14.2

case "$(uname -m)" in
  x86_64) arch=x86_64 ;;
  aarch64|arm64) arch=aarch64 ;;
  *) echo "::error::no git-cliff build for $(uname -m)"; exit 1 ;;
esac
asset="git-cliff-${GIT_CLIFF_VERSION}-${arch}-unknown-linux-musl.tar.gz"
base="https://github.com/orhun/git-cliff/releases/download/v${GIT_CLIFF_VERSION}"
dir="${RUNNER_TEMP:?}/git-cliff"
mkdir -p "$dir"
cd "$dir"
curl -sSfLO "${base}/${asset}"
curl -sSfLO "${base}/${asset}.sha512"
sha512sum -c "${asset}.sha512"
tar -xzf "$asset" --strip-components=1 "git-cliff-${GIT_CLIFF_VERSION}/git-cliff"
./git-cliff --version
echo "path=${dir}/git-cliff" >> "${GITHUB_OUTPUT:-/dev/null}"
