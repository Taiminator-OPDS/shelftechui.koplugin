#!/bin/sh
# Prune + verify + package. Run on every release: python3/luajit build of the
# source tree into dist/, bytecode and translation equivalence checks, zip.
set -e
cd "$(dirname "$0")/.."
LJ=/home/claude/kor/lib/koreader/luajit
export LD_LIBRARY_PATH=/home/claude/kor/lib/koreader/libs
python3 tools/build.py shelftechui.koplugin dist/shelftechui.koplugin
(cd shelftechui.koplugin && find . -name '*.lua') | $LJ tools/verify.lua shelftechui.koplugin dist/shelftechui.koplugin
(cd shelftechui.koplugin && find . -name '*.po') | $LJ tools/verify_po.lua shelftechui.koplugin dist/shelftechui.koplugin
find dist -type d -empty -delete
rm -f /mnt/user-data/outputs/shelftechui.zip
(cd dist && zip -qr -9 /mnt/user-data/outputs/shelftechui.zip shelftechui.koplugin)
ls -la /mnt/user-data/outputs/shelftechui.zip
