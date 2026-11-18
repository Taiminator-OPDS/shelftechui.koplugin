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
# (not the whole of its launcher's tidying up, which can restart the Kindle's
# interface and take half a minute: only until volumd runs again)
volumd_held() {
    p="$(pidof volumd 2>/dev/null | cut -d' ' -f1)"
    [ -n "${p}" ] && grep -q "^State:.*T" "/proc/${p}/status" 2>/dev/null
}
i=0
while volumd_held && [ "${i}" -lt 60 ]; do sleep 1; i=$((i + 1)); done
say "KOReader closed"

# 2. The computer takes the drive: KOReader's folder goes away.
# While KOReader ran, volumd (the Kindle's USB drive service) was held, so a
# cable plugged in meanwhile went unnoticed. It's told again, as a replug
# would: the USB link off and on (then, if need be, the plug-in event). What
# happens goes in the log.
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
if ! gone_within 1 && plugged_ok; then
    # (the USB link off and on, as a replug: what wakes it on a Paperwhite 5;
    # the plug-in event alone didn't)
    for sc in /sys/class/udc/*/soft_connect; do
        [ -w "${sc}" ] || continue
        echo disconnect >"${sc}" 2>>"${LOG}"
        sleep 1
        echo connect >"${sc}" 2>>"${LOG}"
        say "USB link off and on: ${sc}"
    done
    if ! gone_within 4; then
        say "then the plug-in event"
        lipc-send-event com.lab126.hal usbPlugIn >>"${LOG}" 2>&1
        gone_within 4 || say "not yet: a replug will do it"
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
# over USB). Not if it's running or starting already (started by hand
# meanwhile): two launchers fight over the Kindle's own interface, and the
# one that finishes first closes the other's KOReader.
launcher() { ps w 2>/dev/null | grep -v grep | grep -q "koreader.sh"; }
# (a launcher with no KOReader in it is the last one, still tidying up: its
# end is waited for, then it's looked at again)
i=0
while launcher && ! pidof reader.lua >/dev/null 2>&1 && [ "${i}" -lt 90 ]; do sleep 1; i=$((i + 1)); done
sleep 2
running() { pidof reader.lua >/dev/null 2>&1 || launcher; }
cd / || exit 1
if running; then
    say "KOReader is already running or starting: not started again"
else
    say "starting KOReader"
    /bin/sh "${KO_DIR}/koreader.sh" --kual ${FLAGS} </dev/null >/dev/null 2>&1 &
fi
# (this log, kept beside KOReader to be read over USB: once the drive is
# writable again)
for n in 1 2 3 4 5 6; do
    sleep 5
    cp -f "${LOG}" "${KO_DIR}/stui_usbdrive.log" 2>/dev/null && break
done
exit 0
