#!/bin/sh
# ShelfTechUI: USB drive mode on a Kindle (bos_usbdrive.lua).
#
# KOReader lives on the partition a computer takes over in USB drive mode, so
# it can't stay running: it closes, the Kindle's own USB drive mode runs, and
# when the computer lets go (ejected, or unplugged) this starts KOReader again.
#
# Runs from /var/tmp (a copy), since the shared partition goes away while the
# computer has it. Arguments: KOReader's folder, then koreader.sh's flags.
#
# Waits: KOReader closing (60 s at most), the computer taking the drive
# (90 s: if it never does, KOReader comes back), the drive coming back.

KO_DIR="${1}"
shift
FLAGS="$*"
LOG=/var/tmp/stui_usbdrive.log
say() { echo "$(date '+%H:%M:%S') ${1}" >>"${LOG}"; }
echo "" >"${LOG}"
say "start: ${KO_DIR} ${FLAGS}"

# 1. KOReader closes, and its launcher finishes (which lets USB drive mode run)
i=0
while pidof reader.lua >/dev/null 2>&1 && [ "${i}" -lt 60 ]; do sleep 1; i=$((i + 1)); done
i=0
while ps w 2>/dev/null | grep -v grep | grep -q "/var/tmp/koreader.sh" && [ "${i}" -lt 60 ]; do sleep 1; i=$((i + 1)); done
say "KOReader closed"

# 2. The computer takes the drive: KOReader's folder goes away
i=0
while [ -e "${KO_DIR}/reader.lua" ] && [ "${i}" -lt 90 ]; do sleep 1; i=$((i + 1)); done
if [ -e "${KO_DIR}/reader.lua" ]; then
    say "no USB drive mode after 90 s"
else
    say "USB drive mode"
    # 3. Given back: the folder is there again (and settled)
    while [ ! -e "${KO_DIR}/reader.lua" ]; do sleep 2; done
    say "drive back"
    sleep 4
fi

# 4. KOReader again, as KUAL starts it (this log kept beside it, to be read
# over USB)
say "starting KOReader"
cp -f "${LOG}" "${KO_DIR}/stui_usbdrive.log" 2>/dev/null
cd / || exit 1
/bin/sh "${KO_DIR}/koreader.sh" --kual ${FLAGS} </dev/null >/dev/null 2>&1 &
exit 0
