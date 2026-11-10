# Checks that need a person at the Mac

The terminal that builds openVM cannot focus windows, drag, type into a guest, hear sound or print
to paper. These are the checks left for that reason. Do them with `make app && open .build/openvm.app`,
and write what you saw in `docs/evidence/manual-checks-<date>.md` (pass or fail, and a line on why).
A failure goes back as a bug with the step that showed it.

## In the VM window (both guests)

- [x] **Keyboard.** Type letters, digits and symbols; a non-US layout key (an accented letter, a
      dead key); hold a key to repeat it.
- [x] **Shortcuts.** Cmd+C, V, Q, W, Tab in a windowed guest and in full screen. Cmd+Q must not quit
      the app silently while a guest has focus.
- [x] **Pointer.** Clicks, drag and right-click work; scrolling runs the wrong way (see Scrolling). Clicks land where the pointer is, on a Retina display; drag, scroll, right-click.
- [ ] **Scrolling.** Scrolling in a guest runs the same way as on the Mac, on a trackpad and a mouse. View ▸ Reverse Scrolling is meant to switch it (known not to work on a trackpad, see `docs/gui-notes.md`).
- [x] **Idle.** Leave the window open and idle for 12 minutes, then type. The guest must answer
      (Windows Modern Standby idles at 5.5 minutes).
- [x] **Resize.** Drag the window edge slowly and quickly; the guest desktop follows without a
      failure screen. Enter and leave full screen. Note how long it takes to settle.
- [x] **Move between displays** (if you have two): the guest re-fits.
- [x] **Close and reopen.** Close the window; the VM keeps running; reopen it from the menu bar.
- [x] **Quit.** Quit the app with a guest running: the dialog names it; the guest shuts down cleanly.
- [x] **Sleep.** Close the lid or sleep the Mac with a window open; wake it; the guest resumes.

## Clipboard

- [ ] Copy text in a Mac app, click into the VM window, paste in the guest.
- [ ] Copy in the guest, click out to the Mac, paste.
- [ ] Copy from a password manager, click into the VM: nothing arrives, and the window subtitle
      says the clipboard was marked private.
- [ ] Untick Devices ▸ Share Clipboard: nothing moves either way.
- [ ] Copy more than 512 KiB of text: it is skipped, and the subtitle says so.

## Files

- [ ] **Drop in.** Drag from Finder onto the window: one file, a folder, a file with a non-Latin
      name, a photo from Photos, a 1 GiB file. The guest keeps answering while it copies. Mouse input
      still works over the whole screen.
- [ ] **Send out, Linux.** In Thunar, right-click a file, "Send to Mac". It appears in
      `~/Downloads/openVM/<vm>/`, and the window says so.
- [ ] **Send out, Windows.** In Explorer, right-click a file, Send to, "Send to Mac".
- [ ] **A 12 x 200 MB tree** from Windows: bytes match on the Mac (compare with `cmp` or `shasum`).
- [ ] **Outbox off.** Settings, turn off "Accept files this VM sends to the Mac": a send is not
      taken.

## Restart

- [x] **Linux.** Run `reboot` in a guest with its window open. It comes back by itself.
      Run `poweroff`: it stays stopped.
- [x] **Windows.** Restart from the Start menu. It comes back by itself (2026-11-10).

## Printing and sound (moved here from M3)

- [ ] **Print, Linux and Windows.** Add a real printer (or a PDF queue) to the Mac, print from each
      guest. Paper or a real PDF comes out.
- [ ] **Default printer.** Change the Mac's default; the guest's default follows. If not, find why
      and fix it test-first in `PrinterBridge.swift`.
- [ ] **Sound.** Linux: works (2026-11-10). Windows: not yet checked. Play a sound in each guest; note the latency. On Windows this needs Test Mode
      (Settings, Sound, with the warning).
- [ ] **Screen recording** of the integration features, for the docs.

## The app

- [x] **Windows account.** Create a Windows VM with your own user name and password; `net localgroup administrators` lists it, and Run as administrator works. Try it once with automatic sign-in off.
- [x] **Wizard.** Create a Linux VM and a Windows VM from the wizard alone. Cancel one install at
      each stage and check nothing is left in `~/.openvm` or the list. The ISO chooser accepts only
      `.iso`; closing the window mid-run asks first.
- [x] **Menus, library and Settings.** Every menu item does what it says, for the current VM, in the menu bar and under the icon; CPU and memory are locked while a VM
      runs; sound warning appears before Windows sound turns on.
- [x] **Menu bar icon** is the computer symbol; its menu ticks the current VM, shows its state, and its View, Actions and Devices submenus work with the app in the background.
- [x] **Library cards** show a picture of each running VM after a while (30 seconds, or when you leave its window). If a card stays a plain tile for a running VM, the screen could not be read: tell me.
- [x] **VM window title bar**: dark, with four round buttons that fade when the pointer leaves.
- [ ] **Clean account.** On a new macOS user with no developer tools, do the whole of the above that
      the app offers. Any step that needs the terminal fails this.
