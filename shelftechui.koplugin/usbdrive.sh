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

# 2. The computer takes the drive: KOReader's folder goes away.
# While KOReader ran, volumd (the Kindle's USB drive service) was held, so a
# cable plugged in meanwhile went unnoticed. It's told again (as a replug
# would): the plug-in event, then the USB link off and on. Each try's answer
# goes in the log.
plugged_ok() {
    for f in /sys/devices/platform/charger/charging /sys/devices/platform/fsl-usb2-udc/charging /sys/class/power_supply/*/online; do
        [ -r "${f}" ] && [ "$(cat "${f}" 2>/dev/null)" = "1" ] && return 0
    done
    return 1
}
gone_within() {
    n=0
    while [ -e "${KO_DIR}/reader.lua" ] && [ "${n}" -lt "${1}" ]; do sleep 1; n=$((n + 1)); done
    [ ! -e "${KO_DIR}/reader.lua" ]
}
if ! gone_within 4 && plugged_ok; then
    say "volumd: $(lipc-probe -v com.lab126.volumd 2>&1 | tr '\n' ' ' | cut -c1-600)"
    say "try 1: plug-in event"
    lipc-send-event com.lab126.hal usbPlugOut >>"${LOG}" 2>&1
    sleep 1
    lipc-send-event com.lab126.hal usbPlugIn >>"${LOG}" 2>&1
    if ! gone_within 8; then
        say "try 2: USB link off and on"
        for sc in /sys/class/udc/*/soft_connect; do
            [ -w "${sc}" ] || continue
            echo disconnect >"${sc}" 2>>"${LOG}"
            sleep 2
            echo connect >"${sc}" 2>>"${LOG}"
            say "  ${sc}"
        done
        gone_within 8 || say "not yet: a replug will do it"
    fi
fi
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
cd / || exit 1
/bin/sh "${KO_DIR}/koreader.sh" --kual ${FLAGS} </dev/null >/dev/null 2>&1 &
# (this log, kept beside KOReader to be read over USB: once the drive is
# writable again)
for n in 1 2 3 4 5 6; do
    sleep 5
    cp -f "${LOG}" "${KO_DIR}/stui_usbdrive.log" 2>/dev/null && break
done
exit 0
