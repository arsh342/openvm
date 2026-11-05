# openVM

**Run Windows and Linux on your Mac, connected to macOS like they belong there.**

openVM is a free, open-source virtual machine manager for Apple Silicon. Your guest shares your clipboard, files, printers, sound, screen size and clock with your Mac, so it feels like part of your computer and not a machine in a box.

Built in Swift and C, on Apple's own `Virtualization.framework`.

![Windows 11 running in openVM at Retina scale](docs/images/hidpi-windows-2x.png)

> **Early release.** openVM is command-line only today. The VM window is the next big step, so for now you control guests with `openvmctl` and cannot use a guest's desktop directly.

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
| Drag files into a guest | Yes | Yes |
| Print to your Mac's printers | Yes | Yes |
| Resize the display, 1x to 3x scale | Yes | Yes |
| Sound through your Mac | Yes | Opt-in, see below |
| Clock and time zone follow your Mac | Yes | Yes |
| Safe pause when your Mac sleeps | Yes | Yes |

Guests are Alpine Linux ARM64 with an XFCE desktop, and Windows 11 ARM64.

## Requirements

* An Apple Silicon Mac, on macOS 14 or later
* Swift 6, from Xcode or the Command Line Tools
* For Windows guests: your own Windows 11 ARM64 ISO, plus `wimlib` and `zig` from Homebrew

## Get started

Build openVM, and give the daemon its Virtualization entitlement:

```sh
make check
codesign --force --sign - --entitlements tools/build/vm.entitlements.xml --options runtime .build/debug/openvmd
```

Start the daemon, and leave it running:

```sh
.build/debug/openvmd
```

### Create a Linux guest

```sh
tools/build/fetch-linux.sh           # once
.build/debug/openvmctl create lin
.build/debug/openvmctl start lin     # first start installs Alpine
```

### Create a Windows guest

```sh
tools/build/mk-windows-media.sh <Win11_Arm64.iso> media.raw      # once per ISO
.build/debug/openvmctl create win --boot-mode windows --install-media media.raw --diskSizeMB 65536
.build/debug/openvmctl start win     # first start installs Windows
```

The Windows guest has a local account `openvm` with the password `openvm`. Change it if the guest matters to you.

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

* **Windows sound needs Test Mode.** Windows guests are silent by default, because no Microsoft-signed driver exists for Apple's virtual sound device. `openvmctl audio enable <vm> --test-mode` installs a third-party test-signed driver, then you restart the VM. Test Mode weakens driver signature checks, trusts a third party's certificate in the guest, and shows a desktop watermark. `openvmctl audio disable <vm>` and a restart undo it.
* **Windows guests use a private Apple API.** They need `_setPerformanceMonitoringUnitEmulationEnabled:`, which Apple could remove in any macOS release. It also keeps openVM off the Mac App Store. Linux guests do not use it.
* **Large copies inside Windows can fail.** A bug in the current virtio-win release can fail big reads from a shared folder. openVM's own drops retry around it, but a copy you start inside Windows can still stop with an error.
* **Printing has only been tested with a stand-in printer so far,** not on real paper.

## Roadmap

* A VM window with keyboard and mouse
* Dragging files out of a guest
* Restarting a VM after a reboot from inside the guest
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
Sources/openvmd/          the daemon: VM lifecycle and host-side features
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
