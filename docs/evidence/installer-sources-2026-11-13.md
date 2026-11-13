# Installer sources, 2026-11-13

What each catalog entry resolves from, read on the vendors' own hosts, and a short real run of the host's
download job against them. No full install is recorded here: that is what each entry's own evidence file is for.

## Ubuntu (`ubuntu-lts`)

* Index: `https://cdimage.ubuntu.com/ubuntu/releases/26.04/release/SHA256SUMS` (the folder also holds
  `SHA256SUMS.gpg`, which openVM does not check yet).
* The folder held `ubuntu-26.04-desktop-arm64.iso` and `ubuntu-26.04.1-desktop-arm64.iso` (3.9 GB each), beside
  the server images. The entry takes the highest point release of `ubuntu-<version>-desktop-arm64.iso`.
* The file is served by the same host.

## Fedora (`fedora-workstation`)

* Index: `https://fedoraproject.org/releases.json`. Each item has `version`, `arch`, `link`, `variant`,
  `subvariant`, `sha256` and `size`.
* For `aarch64` Workstation it listed releases 43, 44, 45 and "45 Beta", each with a Live ISO and a raw disk
  image. The entry takes the Live ISO of the highest numbered release, and never a Beta.
* 45: `Fedora-Workstation-Live-45-1.4.aarch64.iso`, 2987100160 bytes. The link is on
  `download.fedoraproject.org`, which redirects to a mirror; the hash comes from `fedoraproject.org`.

## A real run of the download job

`openvmd` on a throwaway home, driven with `openvmctl`. Each download was started, left a few seconds,
cancelled, started again, cancelled, and removed.

```text
$ openvmctl installer fetch ubuntu-lts
$ openvmctl task status <id>
state=running  entry=ubuntu-lts  bytesDone=64487424  bytesPerSecond=16124605  bytesTotal=4154798080  progress=61 MB of 3962 MB
$ openvmctl task cancel <id>
state=cancelled  entry=ubuntu-lts  bytesDone=64880640  bytesTotal=4154798080
$ openvmctl installer fetch ubuntu-lts        # picks up where it stopped
state=running  entry=ubuntu-lts  bytesDone=77086720  bytesPerSecond=4960097  bytesTotal=4154798080

$ openvmctl installer fetch fedora-workstation
state=running  entry=fedora-workstation  bytesDone=1149936  bytesPerSecond=283453  bytesTotal=2987100160
state=cancelled  entry=fedora-workstation  bytesDone=1166302
state=running  entry=fedora-workstation  bytesDone=1336115   # picked up again

$ openvmctl installer list
entry=fedora-workstation  file=Fedora-Workstation-Live-45-1.4.aarch64.iso  path=…/isos/fedora-workstation-Fedora-Workstation-Live-45-1.4.aarch64.iso.part  bytes=1336115  complete=false
entry=ubuntu-lts  file=ubuntu-26.04.1-desktop-arm64.iso  path=…/isos/ubuntu-lts-ubuntu-26.04.1-desktop-arm64.iso.part  bytes=77414400  complete=false
$ openvmctl installer remove ubuntu-lts
freedBytes=77414400
```

What this shows: both indexes resolve to the current file over HTTPS, the size the server gives matches the
index, a stopped download keeps its part, and the next start asks for the rest. What it does not show: a
download run to the end and verified against the real hash (the fixture tests cover the check itself), or
that either system installs and runs in openVM.
