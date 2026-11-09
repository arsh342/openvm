#!/bin/sh
# wim-job.sh — every wimlib step of building Windows media, in one script that runs wherever
# wimlib is: on the Mac (if it has wimlib-imagex), or inside the helper VM, where Alpine
# provides it. See docs/windows-guests.md.
#
#   usage: wim-job.sh <iso-root> <job-dir>
#
#   <iso-root>/sources/install.wim, boot.wim   the Windows ISO, read-only
#   <job-dir>/pe/                               the staged WinPE payload (without the two files below)
#   <job-dir>/unattend.xml.in                   the answer-file template, with an @LANG@ placeholder
#   <job-dir>/winpeshl.ini                      what WinPE runs instead of Setup
#
# Writes <job-dir>/boot.wim (the ISO's, with /openvm and winpeshl.ini added) and
# <job-dir>/result ("<image index> <language>").
set -eu

ISO=${1:?usage: wim-job.sh <iso-root> <job-dir>}
JOB=${2:?usage: wim-job.sh <iso-root> <job-dir>}

install_wim="$ISO/sources/install.wim"
[ -f "$install_wim" ] || { echo "wim-job: the ISO has no sources/install.wim" >&2; exit 1; }

image_index=$(wimlib-imagex info "$install_wim" | awk '/^Index:/{i=$2} /^Name: *Windows 11 Pro$/{print i; exit}')
[ -n "$image_index" ] || { echo "wim-job: install.wim has no 'Windows 11 Pro' image" >&2; exit 1; }
image_lang=$(wimlib-imagex info "$install_wim" "$image_index" | awk -F': *' '/^Default Language:/{print $2; exit}')
[ -n "$image_lang" ] || image_lang=en-US

# cmd wants CRLF; labels and goto misbehave on bare LF.
printf '%s\r\n' "$image_index" > "$JOB/pe/image-index.txt"
sed "s/@LANG@/$image_lang/g" "$JOB/unattend.xml.in" > "$JOB/pe/unattend.xml"

cp "$ISO/sources/boot.wim" "$JOB/boot.wim"
chmod u+w "$JOB/boot.wim"  # the ISO's copy is read-only; wimlib rewrites this one
boot_index=$(wimlib-imagex info "$JOB/boot.wim" | awk -F': *' '/^Boot Index:/{print $2; exit}')
[ -n "$boot_index" ] || { echo "wim-job: boot.wim has no boot image" >&2; exit 1; }
wimlib-imagex update "$JOB/boot.wim" "$boot_index" >/dev/null <<WIMCMDS
add $JOB/pe /openvm
add $JOB/winpeshl.ini /Windows/System32/winpeshl.ini
WIMCMDS

echo "$image_index $image_lang" > "$JOB/result"
