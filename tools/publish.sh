#!/bin/sh
# Publish the version in _meta.lua: run the full local release (build, the
# bytecode and translation checks), make sure CHANGELOG.md has its notes,
# then tag it and push. GitHub Actions builds the zip and publishes the
# release; Storefront shows it as an update.
#
#   sh tools/publish.sh          a release
#   sh tools/publish.sh beta.1   a pre-release, v<version>-beta.1
set -e
cd "$(dirname "$0")/.."
v=$(sed -n 's/.*version = "\([^"]*\)".*/\1/p' shelftechui.koplugin/_meta.lua)
grep -q "^## $v" CHANGELOG.md || { echo "CHANGELOG.md has no '## $v' section" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Commit your changes first" >&2; exit 1; }
sh tools/release.sh
tag="v$v${1:+-$1}"
git tag -a "$tag" -m "ShelfTechUI $tag"
git push origin HEAD "$tag"
echo "Pushed $tag: the release builds on GitHub in a minute or two."
