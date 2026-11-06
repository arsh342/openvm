# Changelog

## Unreleased

First public version.

* Linux (Alpine ARM64, XFCE) and Windows 11 ARM64 guests, installed automatically
* Clipboard, file transfer, shared folders and drag and drop into a guest
* Printing to the Mac's printers
* Dynamic resolution and 1x to 3x scale
* Sound out, with Windows as an opt-in
* Clock and time zone sync, and pausing guests when the Mac sleeps
* The openVM app: a window for each VM with keyboard, mouse and live resizing, a VM library, a creation wizard, a menu-bar icon and per-VM settings
* The clipboard follows window focus (text only, never anything a password manager marks private)
* Files sent from a guest to the Mac land in Downloads/openVM, marked as downloaded
* A Linux guest that restarts itself is started again
* Any other ARM64 Linux can be installed from its own ISO, with its own installer; these guests have no openVM tools yet
* The wizard asks for the Windows user name and password, and whether to sign in automatically
