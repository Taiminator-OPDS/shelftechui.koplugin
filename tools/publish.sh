#!/bin/sh
# Publish the version in _meta.lua: check CHANGELOG.md has its notes, run the
# full local release (build, bytecode and translation checks), then push
# main. On GitHub, the Release workflow sees the new version and publishes
# release v<version> (a version like 1.5.0-beta.1 becomes a pre-release);
# Storefront shows it as an update.
set -e
cd "$(dirname "$0")/.."
v=$(sed -n 's/.*version = "\([^"]*\)".*/\1/p' shelftechui.koplugin/_meta.lua)
grep -q "^## $v" CHANGELOG.md || { echo "CHANGELOG.md has no '## $v' section" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Commit your changes first" >&2; exit 1; }
sh tools/release.sh
git push origin main
echo "Pushed $v: release v$v builds on GitHub in a minute or two."
