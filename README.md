# openVM

**Run Windows and Linux on your Mac, connected to macOS like they belong there.**

openVM is a free, open-source virtual machine manager for Apple Silicon. Your guest shares your clipboard, files, printers, sound, screen size and clock with your Mac, so it feels like part of your computer and not a machine in a box.

Built in Swift and C, on Apple's own `Virtualization.framework`.

![Windows 11 running in openVM at Retina scale](docs/images/hidpi-windows-2x.png)

> **Early release.** openVM now has a window for each VM, a library, a setup wizard and a menu-bar icon, and everything still works from `openvmctl` too. Several parts have been tested by script but not yet by hand in the app; the list is in [docs/manual-checks.md](docs/manual-checks.md).

## Why openVM

* **Built on Apple's hypervisor.** ARM guests run directly on your Mac's CPU, with no translation layer.
* **Deep integration.** The connection between macOS and the guest is the product, not an add-on.
* **Automatic installs.** Linux installs itself on first start, and Windows installs unattended from your own ISO.
* **Retina ready.** Guest desktops scale to 2x and 3x, at your Mac's native resolution.
* **Free and open.** Apache 2.0 licensed, with no account and no subscription.

## Features

| Feature | Linux | Windows |
| --- | --- | --- |
| Clipboard | Yes | Yes |
| File transfer | Yes | Yes |
| Shared folders | Yes | Yes |
| A window for each VM, with keyboard and mouse | Yes | Yes, at 1024 pixels wide for now |
| Clipboard follows focus (text; passwords are never shared) | Yes | Yes |
| Drag files into a guest | Yes | Yes |
| Send files from a guest to your Mac | Yes | Yes |
| A guest that restarts itself is started again | Yes | Not yet |
| Print to your Mac's printers | Yes | Yes |
| Resize the display, 1x to 3x scale | Yes | Not in its window yet |
| Sound through your Mac | Yes | Opt-in, see below |
| Clock and time zone follow your Mac | Yes | Yes |
| Safe pause when your Mac sleeps | Yes | Yes |

Guests are Alpine Linux ARM64 with an XFCE desktop, and Windows 11 ARM64.

## Requirements

* An Apple Silicon Mac, on macOS 14 or later
* Swift 6, from Xcode or the Command Line Tools
* For Windows guests: your own Windows 11 ARM64 ISO. Nothing else to install: openVM builds the install media itself, using `wimlib` from Homebrew if the Mac has it, and otherwise a short-lived Alpine helper VM that carries its own copy (it needs the Linux guest files, below). `zig` and `lld` are only needed to build openVM's payload from source

## Get started

Build openVM, the guest payload (the files a guest is built from), and the daemon's signature, which gives it the Virtualization entitlement:

```sh
make check
make payload
codesign --force --sign - --entitlements tools/build/vm.entitlements.xml --options runtime .build/debug/openvmd
```

Start the daemon, and leave it running. It finds the payload in `.build/payload` when started from this directory, or wherever `OPENVM_PAYLOAD` points:

```sh
.build/debug/openvmd
```

Or build the app, which carries its own payload, hosts the VMs itself, and shows each one in a window (use one or the other, not both):

```sh
make app
open .build/openvm.app
```

The app's wizard creates Linux and Windows guests for you: it fetches what Linux needs, checks and converts your Windows ISO, and installs. The commands below do the same by hand.

### Create a Linux guest

Fetch the Linux files once, then create and start a guest:

```sh
.build/debug/openvmctl task start fetch-linux        # prints a task id
.build/debug/openvmctl task status <task-id>         # progress, until state=done
.build/debug/openvmctl create lin
.build/debug/openvmctl start lin     # first start installs Alpine, and takes a few minutes
```

`tools/build/fetch-linux.sh` does the same fetch by hand, but needs a C compiler; the task uses the unpacker shipped in the payload instead.

### Create a Windows guest

Check that the ISO is one openVM can use, then build the install media (about a minute, once per ISO). It goes in `$OPENVM_HOME/media`:

```sh
.build/debug/openvmctl windows-iso check ~/Downloads/Win11_Arm64.iso
.build/debug/openvmctl task start windows-media --iso ~/Downloads/Win11_Arm64.iso --name win   # prints a task id
.build/debug/openvmctl task status <task-id>                                                    # until state=done
.build/debug/openvmctl create win --boot-mode windows --install-media ~/.openvm/media/win.raw --diskSizeMB 65536
.build/debug/openvmctl start win     # first start installs Windows
```

Without `wimlib` on the Mac, fetch the Linux files first (`openvmctl task start fetch-linux`): the media is then built in a helper VM. The media needs about 22 GB of disk while it exists.

From the wizard you choose the Windows user name and password. Built by hand, the guest has an administrator account `openvm` with the password `openvm`, so change it if the guest matters to you.

## Using a guest

```sh
openvmctl list                                       # your VMs
openvmctl clipboard push win                         # send your clipboard to the guest
openvmctl file push win report.pdf                   # copy a file in
openvmctl share add win ~/Projects                   # share a folder
openvmctl drag drop win ~/Downloads/photo.jpg        # put a file on the guest's Desktop
openvmctl display set win --width 2560 --height 1664 --scale 2
openvmctl suspend win
openvmctl stop win
```

Run `openvmctl` with no arguments to see every command.

## Before you rely on it

* **A Windows guest runs at 1024 pixels wide in its window for now.** Any other width scrambles the picture, so the app holds that width and scales it up, which looks softer than your display can show. See [docs/gui-notes.md](docs/gui-notes.md).
* **Building Windows media may need a newer macOS than the app does.** The media script uses `diskutil image`, which older releases of macOS do not have. It has only been run on macOS 27.
* **Windows sound needs Test Mode.** Windows guests are silent by default, because no Microsoft-signed driver exists for Apple's virtual sound device. `openvmctl audio enable <vm> --test-mode` installs a third-party test-signed driver, then you restart the VM. Test Mode weakens driver signature checks, trusts a third party's certificate in the guest, and shows a desktop watermark. `openvmctl audio disable <vm>` and a restart undo it.
* **Windows guests use a private Apple API.** They need `_setPerformanceMonitoringUnitEmulationEnabled:`, which Apple could remove in any macOS release. It also keeps openVM off the Mac App Store. Linux guests do not use it.
* **Large copies inside Windows can fail.** A bug in the current virtio-win release can fail big reads from a shared folder. openVM's own drops retry around it, but a copy you start inside Windows can still stop with an error.
* **Printing has only been tested with a stand-in printer so far,** not on real paper.

## Roadmap

* Dragging files out of a guest, straight from its window (files can be sent with "Send to Mac" today)
* Restarting a Windows VM after a reboot from inside the guest
* Microphone
* Windows sound without Test Mode

## For developers

```sh
make check                                       # build, Swift tests, guest agent tests
OPENVM_SMOKE_REAL=1 tools/test/daemon-smoke.sh   # real Linux install, about 10 minutes
make windows-smoke ISO=<windows-iso>             # real Windows install, about 30 minutes
```

See [docs/testing.md](docs/testing.md) for what each one covers.

```
Sources/OpenVMCore/       wire protocol, VM registry, shared rules
Sources/OpenVMWindows/    the Windows VM configuration
Sources/OpenVMHost/       the host library: VM lifecycle and host-side features
Sources/OpenVMApp/        the app: VM windows, library, wizard, menu bar
Sources/openvmd/          a headless host, for scripts and the smokes
Sources/openvmctl/        the command-line client
Sources/openvm-mockguest/ a guest stand-in for tests
Tests/                    Swift tests
tools/build/              fetching guest parts, building agents and install media
tools/test/               C agent tests and the real-guest smokes
tools/guest/              the guest agents and the shared wire codec
tools/uefi/               the boot chain Windows guests start from
tools/windows/            install and first-boot scripts for Windows guests
docs/                     protocol, VM config and Windows guest notes
```

## Documentation

Start with [docs/README.md](docs/README.md). To contribute, see [CONTRIBUTING.md](CONTRIBUTING.md), and to report a security problem, see [SECURITY.md](SECURITY.md).

## License

Apache License 2.0. See `LICENSE`.

Windows, its drivers and the optional sound driver are not part of openVM and keep their own licenses. They are fetched or built from your own media on your machine. The optional sound driver comes from the [Droid-VM](https://github.com/Droid-VM/gunyah-guest-drivers-windows) project.
