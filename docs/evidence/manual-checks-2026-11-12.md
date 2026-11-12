# Manual checks, 2026-11-12

Done by the owner in the app, on the Windows 11 lab guest `win-lab` and an Omarchy guest installed from its ISO.
Reported results, as given.

| Check | Linux (Omarchy, from its ISO) | Windows |
| --- | --- | --- |
| Scrolling | Works, but runs opposite to the Mac's direction | The same |
| Clipboard | Works inside the guest; nothing is shared with the Mac | Works both ways |
| Display | | Every size right with a fixed `viogpudo`; Full Size Display gave the window's full Retina size |

The Linux clipboard result is expected: a guest installed from its own ISO has no openVM tools, and the Spice
clipboard covers X11 desktops only. Files and printing were left for later.
