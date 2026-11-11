# Changelog

## Unreleased

First public version.

* openVM no longer makes its own Alpine Linux guest: Linux installs from the distribution's own ISO, as Windows does. Alpine VMs made earlier are listed but not started, and can be deleted. `create` now needs `--boot-mode windows` or `--boot-mode linux-iso`. The View menu's Retina Resolution items went with it, as no remaining guest used them

* Windows 11 ARM64 guests, installed unattended from your own ISO
* Clipboard, file transfer, shared folders and drag and drop into a guest
* Printing to the Mac's printers
* A Windows guest stays at 1024 pixels wide in its window for now
* Sound out, with Windows as an opt-in
* Clock and time zone sync, and pausing guests when the Mac sleeps
* The openVM app: a window for each VM with keyboard, mouse and live resizing, a VM library, a creation wizard, a menu-bar icon and per-VM settings
* The clipboard follows window focus (text only, never anything a password manager marks private)
* Files sent from a guest to the Mac land in Downloads/openVM, marked as downloaded
* A Windows guest that restarts itself comes back
* Any ARM64 Linux can be installed from its own ISO, with its own installer; these guests have no openVM tools yet
* Those guests can share the clipboard through macOS's own Spice agent, if you turn it on and install `spice-vdagent`
* A PipeWire setting for those guests, without which they are silent: the VM's sound device plays nothing in the small chunks PipeWire uses by default
* The wizard asks for the Windows user name and password, and whether to sign in automatically
