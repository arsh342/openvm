# Ubuntu from its tile, 2026-11-13

Reported by the owner, who did this in the app on this Mac (macOS 27.2.1). Nothing here was measured from the
terminal: these are the owner's results, as given, with what is not recorded said plainly.

| Step | Result |
| --- | --- |
| Download from the Ubuntu tile | Finished. The library's Downloads list showed `ubuntu-26.04.1-desktop-arm64.iso`, 4.15 GB, "Downloaded and checked" (the owner's screenshot), so the file matched the SHA-256 in Canonical's `SHA256SUMS` and passed the installer check |
| Install | Ubuntu installed ("ubuntu is installed") |
| After the installer's restart | "Remove Installer and Start" appeared on the stopped VM |
| Sound | Works |

**Not recorded:** whether the guest needed the PipeWire setting from the README before sound worked (the tile
still says it does); resizing; the clipboard; how long the install took; the VM's CPUs, memory and disk.

**Fedora.** No Fedora install is on record. The owner listed its tile on the strength of this result ("fedora
will work as well"): both are installed the same way, from the distribution's own ISO. Its download was run for
a few seconds against Fedora's servers (`installer-sources-2026-11-13.md`), not to the end.
