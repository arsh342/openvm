# Architecture

openVM has three kinds of program: a daemon on the Mac, a command-line client, and an agent inside each guest.

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
| Linux agent | `tools/guest/openvm-tools.c` | Answers the host inside a Linux guest |
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

* **Linux:** the kernel boots directly. The first start installs Alpine to the disk from the install overlay in the guest payload (built by `tools/build/mk-payload.sh`, which runs `tools/build/mk-guest-overlay.sh`), which the host serves to the guest, and later starts boot the installed system.
* **Windows:** the firmware loads `tools/uefi/openvm-efi.c`, which provides a framebuffer and starts Windows Boot Manager. The first start runs an unattended install from media built by `tools/build/mk-windows-media.sh`.
