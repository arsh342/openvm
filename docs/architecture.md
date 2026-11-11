# Architecture

openVM has four kinds of program: the app and a headless daemon on the Mac (either one hosts the VMs), a command-line client, and an agent inside each Windows guest.

```
openvmctl ──Unix socket──▶ openvmd ──vsock port 52──▶ guest agent
                              │
                              └── Virtualization.framework runs the VM
```

| Part | Where | Job |
| --- | --- | --- |
| `OpenVMHost` | `Sources/OpenVMHost` | The host library. Owns the VMs: boots and stops them, serves the socket, and drives every host-side feature |
| `openvmd` | `Sources/openvmd` | The headless host: a thin `main` over `OpenVMHost`, with no windows. One host runs per `OPENVM_HOME`; a second is refused, naming the holder's pid |
| `openvm.app` | `Sources/OpenVMApp` | The app. Hosts the VMs itself through `OpenVMHost` (a VM window needs the live machine in its own process) and still serves the socket, so `openvmctl` works against it. Build it with `make app` |
| `openvmctl` | `Sources/openvmctl` | Turns commands into daemon requests and prints the replies |
| `OpenVMCore` | `Sources/OpenVMCore` | Code the host, the CLI and the app share: the wire protocol, the VM registry, the client (`DaemonClient`), and the rules for each feature |
| `OpenVMWindows` | `Sources/OpenVMWindows` | The Virtualization.framework configuration for Windows guests |
| Linux agent | `tools/guest/openvm-tools.c` | The same for Linux. Kept and tested, but no guest installs it: Linux guests come from their own ISO, with no openVM tools yet |
| Windows agent | `tools/guest/openvm-tools-win.c` | The same, as a Windows service |

## How a request flows

Taking `openvmctl display set win --width 2560 --height 1664 --scale 2`:

1. `openvmctl` parses the command and sends a `vmRequest` over the Unix socket (`DaemonClient.swift`).
2. `Server.swift` (in `OpenVMHost`) reads the frame and hands it to `vmOp`, which calls the handler for that op (`VmRequest.swift`).
3. The handler finds the VM and its live guest, and checks the arguments (`GuestOps.swift`).
4. `DisplayControl.swift` resizes the framework's display, then sends a `displayRequest` through `GuestChannel.swift`.
5. The agent applies the mode and scale, and replies with what the guest really holds.
6. The daemon compares that with the request, so success means the guest changed.

Every feature follows this path. A handler lives in one of `VmRecordOps`, `VmPowerOps`, `ShareOps` or `GuestOps`, and every guest request goes through the single `exchange` function in `GuestChannel.swift`.

## Daemon threading

Virtualization.framework needs the main dispatch queue, so the main thread owns the run loop and the socket runs on its own thread. Handlers block on the guest channel, so they must never run on the main actor.

## Guest agents

Each agent is one C program with a file per feature, in `tools/guest/linux` and `tools/guest/windows`, included in order into one compile unit. Both use `tools/guest/ovmc_codec.h`, so they cannot disagree about the wire format.

The agent answers one request at a time, so slow work must not run in a handler. A request that cannot connect within 2 seconds fails. See [Windows guests](windows-guests.md).

## Trust

A guest is not trusted. Every value from a guest is checked before the host acts on it: a print job must name a printer published to that guest, and paths and names are validated on both sides. The daemon never runs a shell with guest data.

## Boot

* **Linux:** a plain UEFI machine with the distribution's ISO on a USB stick. The person runs the distribution's own installer in the VM window, then ejects the ISO (`GuestLinuxISO.swift`). There is no agent, so readiness is the firmware having the machine, and the clipboard, if turned on, goes through the framework's Spice agent.
* **The helper VM:** a short-lived Alpine netboot guest that builds Windows media when the Mac has no wimlib (`WimHelperVM.swift`). It boots the kernel fetched by `fetch-linux` with the overlay from `tools/build/mk-guest-overlay.sh`, runs one job on two shared folders and powers off. It is not a VM anyone can create or open.
* **Windows:** the firmware loads `tools/uefi/openvm-efi.c`, which provides a framebuffer and starts Windows Boot Manager. The first start runs an unattended install from media built by `tools/build/mk-windows-media.sh`.
