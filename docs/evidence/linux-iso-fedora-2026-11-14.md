# Fedora Workstation from its tile, 2026-11-14

Reported by the owner, who did this in the app on this Mac (macOS 27.2.1), with the VM `linux-vm-3`.

| Step | Result |
| --- | --- |
| Download from the Fedora tile | Finished and checked (`Fedora-Workstation-Live-45-1.4.aarch64.iso`) |
| Install | Fedora installed |
| Installed system | Boots. The VM's console (`linux-vm-3.console.log`) shows the installed system's login prompt: "Fedora Linux 45 (Workstation Edition), Kernel 7.2.11-300.fc45.aarch64 on aarch64 (hvc0)" |
| Scrolling | Runs the opposite way to the Mac. Ubuntu's did not |

**Why the scrolling differs.** The VM's pointer scrolls the way the fingers move and openVM cannot change that
from the Mac (`docs/evidence/scroll-direction-2026-11-12.md`); the guest decides. GNOME's natural scrolling for a
mouse is off unless set, and the VM's pointer is a mouse. Settings ▸ Mouse & Touchpad ▸ Mouse ▸ Natural
Scrolling in Fedora fixes it (README, "If scrolling runs the wrong way"). Why Ubuntu's runs the Mac's way was not
looked into. The Fedora tile now says this before anything is downloaded.

**Not recorded:** sound, with or without the PipeWire setting; resizing; how long the install took.
