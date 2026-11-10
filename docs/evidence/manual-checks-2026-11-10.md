# Manual checks, 2026-11-10

Done by the owner in the app, on a Windows 11 guest and an Omarchy guest installed from its ISO, both created
from the wizard. Reported results, as given.

| Check | Linux (Omarchy) | Windows |
| --- | --- | --- |
| Keyboard, shortcuts, pointer | Pass | Pass |
| Scrolling | Fail: runs against the fingers, and View ▸ Reverse Scrolling changes nothing | Fail: the same |
| Resize, move between displays | Pass | Pass |
| Idle, close and reopen, sleep, quit | Pass | Pass |
| Restart | Pass | Pass, from the Start menu |
| Sound | Pass | Not checked |
| Clipboard | Works inside the guest only: nothing moves to or from the Mac | Works both ways (checked earlier) |
| Wizard, menus, library, settings, menu bar icon, title bar | Pass | Pass |

The Omarchy clipboard result is expected: a guest installed from its own ISO has no openVM guest tools, and the
clipboard goes through them (README, "Install another Linux from its ISO").

Windows restart was listed as a known bug (restarting from the Start menu stops the VM). The owner confirmed a
restart from the Start menu comes back by itself, so that bug is closed: it had been written down without a test.

Still open: printing, Windows sound, the file checks (drop in, Send to Mac, the 12 x 200 MB tree, outbox off), the
clipboard edge cases (password manager, the switch, oversized text), the screen recording, and the clean-account run.
