# VM records

The persisted VM config schema, and an audit of the Virtualization.framework APIs
in use.

## Schema

Storage: `$OPENVM_HOME/vms.json` — one JSON array of VM records, rewritten
atomically per change (`Sources/OpenVMCore/Registry.swift`). There is no
per-VM config file yet; the record *is* the config.

```json
{
  "uuid":      "A1B2C3D4-…",          // UUID string; registry key
  "name":      "srv1",                 // [A-Za-z0-9_-]{1,64}, first char alphanumeric
  "state":     "stopped|starting|running|suspended|stopping",
  "cpus":      4,                      // 1…32 (validated at create/set)
  "memoryMB":  4096,                   // ≥128
  "diskPath":  "…/disks/srv1/disk.raw", // present iff a raw disk was provisioned
  "timezone":  "Europe/Berlin",         // optional IANA zone; absent = guest default
  "clipboardSync": true,                 // optional; share the clipboard with this VM; absent = true, false for linux-iso
  "outbox":    true,                       // optional; take files the guest sends to the Mac; absent = true
  "shares":    [                          // optional shared folders; absent = none
    {"hostPath": "/Users/me/Projects", "guestPath": "/mnt/openvm/Projects"}
  ],
  "bootMode":  "windows|linux-iso",      // optional only for old records: absent or "linux" = a retired Alpine guest
  "variableStorePath": "…/nvram.bin",   // optional; Windows EFI variable store
  "installMediaPath":  "…/media.raw",   // optional; Windows install media
  "machineIdentifier": "…",             // optional; Windows, base64, kept for the VM's lifetime
  "createdAt": "2026-10-21T09:00:00Z"  // ISO8601
}
```

Field semantics beyond the obvious:

* `state` is the registry's view, not a hypervisor fact. A daemon restart or
  crash leaves records that may disagree with reality (real machines die with
  the daemon process); `stop`/`resume` handle the reconciliation rules per op
  (see `docs/daemon-protocol.md`). `starting`/`stopping` exist in the state
  set but are never written today — they are reserved for async lifecycle.
* `bootMode` is `windows` or `linux-iso` for every VM made now. A record with `linux`, or with no
  `bootMode` at all, is an Alpine guest an earlier openVM made (`BootMode.alpine`, which keeps the
  spelling `linux` because a value the reader does not know fails the whole registry read). Such a
  VM is listed, can have its CPUs, memory and time zone changed, and can be deleted; `start` and
  `set --boot-mode` refuse it.
* Sidecar files referenced by `diskPath` are not part of the record:
  `<diskPath>.openvm-installed` (an install has finished), and on an old Alpine disk
  `.openvm-kernel` and `.openvm-initramfs`. `delete` sweeps all of them.
* `clipboardSync` is optional and absent in records written before the field existed; absent
  means on, except for a `linux-iso` guest, where it means off (its clipboard goes through the
  framework's Spice agent, which has no password filter, and is set when the VM starts). It is a per-VM policy the person can change while the VM runs, as the time zone
  can; CPUs and memory cannot, because they are read when the VM boots.
* `timezone` is optional and absent in records written before the field
  existed — a missing key must keep decoding, so every field added after v1 is
  `Optional`. The zone is pushed to the guest with the host clock at boot and
  after a resume; the guest points `/etc/localtime` at the zoneinfo file.
* `shares` is optional for the same reason: records written before shared
  folders existed have no `shares` key and decode with `nil`. Each entry pairs
  a host directory with the path it is mounted on in the guest; the mount
  itself is established by the daemon (see `docs/daemon-protocol.md`), the
  record only carries the configuration.
* Derived paths are intentionally not persisted: console `<name>.console.log`
  and socket `openvmd.sock` derive from `$OPENVM_HOME`.

### Evolution rules (schema versioning)

Audited behaviour of the current reader (`JSONDecoder` over the synthesized
`Codable` implementation):

* Unknown keys in an existing record are **discarded** silently on read.
* A missing required key **fails the whole decode** (registry reads return
  `io("decode …")`), which the daemon surfaces as an error — the registry
  never silently truncates the VM list.

Rules until a version key is needed:

1. Every field added later must decode as `Optional` so older `vms.json`
   files still load.
2. Removing or renaming a field is a breaking change requiring a
   `schemaVersion` key on the array wrapper (currently no wrapper — add it
   together with the first breaking change).
3. Validation ranges (cpus, memoryMB) are enforced at create/set time by the
   daemon, not by the registry: the registry trusts its file (it must stay
   able to load hand-edited state).

Not yet in the record: network attachment choice and per-device sections. The fixed
values (vsock channel port 52, NAT networking, serial console file) are in the audit
table below. When they become configurable, each moves into the record as an optional
key under rule 1.

## Virtualization.framework APIs in use

Every Virtualization.framework type the daemon configures today, with the
exact call site. Nothing here is inferred: each row names the file that uses
it. macOS-specific availability numbers are not repeated per row; all APIs
below build against the Xcode Swift 6 SDK in use and the package declares
`swift-tools-version: 6.2`.

| API | Role | Call site / note |
|---|---|---|
| `VZVirtualMachineConfiguration` | root config | `GuestBoot.boot`; validated via `try config.validate()` before any device is created |
| `VZLinuxBootLoader` | kernel direct boot | `WimHelperVM.run` only — `kernelURL` + `initialRamdiskURL` + `commandLine`; the helper VM |
| cmdline contract | boot policy | `GuestBoot.netbootCmdline`: Alpine netboot with the pinned modloop and `apkovl=<url>`, plus `openvm.job=wim` |
| `VZVirtioConsoleDeviceSerialPortConfiguration` + `VZFileSerialPortAttachment` | serial console → `<name>.console.log` | `append: false`; readiness polling re-reads this file every 0.5 s |
| `VZVirtioNetworkDeviceConfiguration` + `VZNATNetworkDeviceAttachment` | guest NIC | one NIC, vmnet NAT |
| `VZVirtioSocketDeviceConfiguration` + `VZVirtioSocketDevice.connect(toPort:)` | the guest channel | daemon↔agent OVMC rides vsock port 52; deliberate substitution for a virtio-console channel (see source comment: FileHandle-attached serial ports never activate) |
| `VZDiskImageStorageDeviceAttachment` + `VZVirtioBlockDeviceConfiguration` | raw sparse disk guest block device | `readOnly: false`; requires the disk already truncated to size (create does this) |
| `VZGenericPlatformConfiguration` | platform identity | Linux: no machine identifier, the VM uuid rides the kernel cmdline (`openvm.uuid=…`); Windows: see below |
| `config.cpuCount`, `config.memorySize` | resources | `cpus`, `memoryMB << 20` |
| `VZVirtualMachine.start()` | boot | async call on the main actor (`VZVirtualMachine` needs the main dispatch queue; ops hop over a `BootWaiter`) |
| `VZVirtualMachine.requestStop()` / `stop()` | shutdown | the agent shuts the guest down; these are the fallback when it does not (`GuestShutdown`) |
| `VZVirtualMachine.pause()` / `resume()` | suspend/resume | state confirmed against `vm.state` before registry transition  |
| `VZEFIBootLoader` + `VZEFIVariableStore` | Windows boot | `GuestWindows.configuration` |
| `VZGenericMachineIdentifier` | Windows machine identity | stored in the record, because Windows ties activation to it |
| `VZVirtioGraphicsDeviceConfiguration` + `VZVirtioGraphicsScanoutConfiguration` | guest display | both guests; `VZGraphicsDisplay.reconfigure(sizeInPixels:)` resizes it (macOS 14) |
| `VZVirtioFileSystemDeviceConfiguration` + `VZMultipleDirectoryShare` + `VZSharedDirectory` | shared folders and drops | tag `openvm`, set replaced live (`SharedFolders`) |
| `VZVirtioSoundDeviceConfiguration` + `VZVirtioSoundDeviceOutputStreamConfiguration` + `VZHostAudioOutputStreamSink` | sound out | `HostAudio.device()` |
| `VZUSBKeyboardConfiguration` + `VZUSBScreenCoordinatePointingDeviceConfiguration` | input for the VM window | both guests; not proved until a window exists |
| `VZVirtualMachineState` | lifecycle truth | values used: `running`, `paused`, `stopped` |

Not configured: 3D acceleration, snapshots (`VZSnapshot`-family APIs) and audio input.

Windows guests also set one private switch, `_setPerformanceMonitoringUnitEmulationEnabled:`, and the fine-grained traps switch (`GuestWindows`). Both are checked for at runtime.

## `openvmctl config schema`

Prints the schema summary above without contacting the daemon (the schema is
a property of the client's version, not of the registry file):

```sh
openvmctl config schema
# exits 2 for `openvmctl config` or unknown config subcommands
```
