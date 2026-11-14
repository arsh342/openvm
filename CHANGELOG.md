# Changelog

## 0.1.0-beta.1 (2026-11-14)

First public version, a beta.

* The app is redesigned around standard Mac controls. A gallery starts a new virtual machine: drop or choose an installer file (openVM tells Windows from Linux by the file), or pick a system. The Windows 11 tile opens Microsoft's download page and says what to expect
* The library is a sidebar, a sortable table (name, system, status, last used, size on disk) and a detail pane. Status is a symbol and a word. Return opens a virtual machine, Space starts or resumes it, Command-Delete deletes after asking
* The menu bar is openVM, File, Edit, View, Virtual Machine, Window and Help. Commands under Virtual Machine act on the window in front, where before they acted on the machine last used. Copy and paste work in openVM's own text fields
* openVM has its own Settings (Command-comma): the menu-bar icon, previews, and downloaded installers. A virtual machine's settings moved to Option-Command-comma
* While a guest has the keyboard, every key combination but a short fixed list goes to the guest
* Each virtual machine's window has a standard toolbar, in place of the round buttons that faded in the title bar
* openVM can download Linux installers itself (`openvmctl installer`, and tiles in the gallery), checked against the maker's published SHA-256, resumable, and kept in `~/.openvm/isos`
* A new app icon, two screens one inside the other, and a menu-bar mark of the same shape. The compiled icon is committed, so a build without Xcode carries it
* Kali Linux joins Ubuntu and Fedora among the systems openVM downloads and installs. All three have been installed through openVM, and their tiles say what each needs (natural scrolling for Ubuntu and Fedora, and what to do if Kali's installer waits on a slow mirror)
* The systems show their makers' marks: Windows, Ubuntu, Fedora and Kali
* A download's progress is in the wizard's button bar, with Pause and Resume; Cancel, or closing the wizard, stops it, keeping what it has
* Failures are a plain title, one sentence and one action, with the technical text behind Details
* A stopped Linux virtual machine that still has its installer offers Remove Installer and Start
* `create --system-name`, and `list` rows with `lastStartedAt`, `systemName`, `createdAt` and `diskUsedBytes`

* openVM no longer makes its own Alpine Linux guest: Linux installs from the distribution's own ISO, as Windows does. Alpine VMs made earlier are listed but not started, and can be deleted. `create` now needs `--boot-mode windows` or `--boot-mode linux-iso`. The View menu's Retina Resolution items went with it, as no remaining guest used them

* Windows 11 ARM64 guests, installed unattended from your own ISO
* Clipboard, file transfer, shared folders and drag and drop into a guest
* Printing to the Mac's printers
* A Windows guest fills its window and full screen, Retina included, and keeps its size when it restarts itself; this needs a `viogpudo` with the virtio-win mode-change fix until a signed release carries it
* Scrolling matches a Mac with natural scrolling: the Windows tools set it, and the README says how in a Linux guest
* Linux guests on Hyprland (Omarchy) follow the window's size with a small script from the README
* Sound out, with Windows as an opt-in
* Clock and time zone sync, and pausing guests when the Mac sleeps
* The openVM app: a window for each VM with keyboard, mouse and live resizing, a VM library, a creation wizard, a menu-bar icon and per-VM settings
* The clipboard follows window focus (text only, never anything a password manager marks private)
* Files sent from a guest to the Mac land in Downloads/openVM, marked as downloaded
* A Windows guest that restarts itself comes back
* Any ARM64 Linux can be installed from its own ISO, with its own installer; these guests have no openVM tools yet
* Those guests can share the clipboard through macOS's own Spice agent, if you turn it on and install `spice-vdagent`
* View ▸ Full Size Display, for a Windows guest whose display driver has the mode-change fix: the guest uses the window's full size, Retina included. Off by default, because the released driver scrambles at any width but 1024
* Windows guests no longer have an invisible second display: the guest tools keep only the VirtIO display on, and leave Windows' fallback display alone if the VirtIO one fails
* A PipeWire setting for those guests, without which they are silent: the VM's sound device plays nothing in the small chunks PipeWire uses by default
* The wizard asks for the Windows user name and password, and whether to sign in automatically
