# Kali Linux from its tile, 2026-11-14

The owner installed Kali from its tile (`kali-linux-2026.3-installer-arm64.iso`, VM `linux-vm-2`, kernel
`7.1.5+kali-arm64`, 4 CPUs, 4 GB), through the text installer.

## First attempt: a kernel panic

The guest showed Linux's panic screen (a penguin and a QR code) part-way through the install, and restarted. The
installer had partitioned the disk and written about 900 MB. The panic's text was not captured: the installer
writes nothing to the VM's console log. **Cause not known.**

## Second attempt: stuck at "Running simple-cdd" (40%, "Finishing the installation")

Measured from the Mac at 20:55: the VM idle (about 0% CPU) and its disk no longer growing (about 14 GB written).
The installer's log (the owner's screenshot of its fourth screen) ends:

```text
15:15:28 finish-install: running postinstall script for: kali
15:15:28 in-target: INFO: setting up kali.sources as the only APT data source
15:15:28 in-target: Get:1 http://mirrors.esto.network/kali kali-rolling InRelease [34.0 kB]
15:15:29 in-target: Get:2 http://mirrors.esto.network/kali kali-rolling/main arm64 Packages [21.8 MB]
15:37:04 in-target: Ign:2 http://mirrors.esto.network/kali kali-rolling/main arm64 Packages
15:37:04 in-target: Get:3 http://mirrors.esto.network/kali kali-rolling/main arm64 Contents (deb) [51.1 MB]
```

So the step is `apt update` against the mirror Kali's redirector chose, `mirrors.esto.network`: 22 minutes on a
21.8 MB file, then given up, and on to a 51.1 MB one.

**The same file fetched from this Mac** (`curl`, 2026-11-14 21:1x):

| Route | Result |
| --- | --- |
| `mirrors.esto.network` over IPv6 (what the Mac picks by itself) | 21792013 bytes in 4.4 s |
| `mirrors.esto.network` over IPv4 (`curl -4`) | 972342 bytes in 90 s, then cut off: about 10 KB/s |
| `kali.download` over IPv4 | 21792013 bytes in 2.2 s |
| `http.kali.org` (the redirector) | sends this Mac to `mirrors.esto.network` |

**Cause, measured:** that mirror is about 10 KB/s over IPv4 from here, and fast over IPv6. The VM reaches the
internet through the framework's NAT over IPv4, so it gets the slow route. It is not the VM's network as such:
the Mac itself is as slow over IPv4 to that mirror, and fast to `kali.download`. Which mirror the redirector
picks depends on where the request comes from, so another Mac may never see this.

**Not measured:** whether the framework's NAT gives the guest IPv6 at all.

## Ways through

* Wait: apt gives up on each file in the end (22 minutes for the first), so the install finishes, slowly.
* Or, in the installer, end the slow download so the step moves on, then point the installed system at a fast
  mirror (`kali.download`) after it boots.

## Through: the install finished, and Kali boots (21:20)

The owner opened a shell in the installer (its second screen), found two `/usr/lib/apt/methods/http` processes,
and killed them. The installer went on and finished. Kali then booted to its login screen in the VM window
(the owner's screenshot: the Kali login over its desktop wallpaper, the panel showing "14 Nov, 21:20").

**Scrolling (the owner, 2026-11-14):** runs the other way until Settings ▸ Mouse and Touchpad ▸ Reverse scroll
direction is ticked in Kali (Xfce); then it matches the Mac.

**Not recorded yet:** sound, resizing; whether the installed system's
package sources still point at the slow mirror (the README says how to switch to `kali.download`).
