# Testing

| Command | Time | Needs |
| --- | --- | --- |
| `make check` | About a minute | Swift |
| `OPENVM_UI_SNAPSHOTS=1 make test` | About ten seconds more | Nothing extra |
| `OPENVM_SMOKE_REAL=1 tools/test/daemon-smoke.sh` | About 10 minutes | Network, for the Alpine install |
| `make windows-smoke ISO=<windows-iso>` | About 30 minutes | A Windows 11 ARM64 ISO, `wimlib`, `zig`, and about 40 GB of disk |

Run `make check` before every commit. Run the matching real smoke when a change touches a guest, the boot path or an install script.

## `make check`

| Suite | Proves |
| --- | --- |
| `Tests/OpenVMCoreTests` | The codec, registry and feature rules, including the generated Linux installer |
| `Tests/OpenVMDaemonTests` | Daemon policy: readiness, shutdown, the clock push and host sleep |
| `tools/test/test-*-agent` | Each Linux agent feature, including hostile input, the Windows agent's build, codec, and hostile input to its drop parser, and `test-send-agent` for the guest send tool |
| `tools/test/conformance.sh` | Golden bytes through the mock guest |

Use `make test`, not `swift test`: with only the Command Line Tools installed, `swift test` cannot find the testing macros, and the Makefile names them.

The Windows agent's real build is checked only when `zig` is installed.

## Real smokes

Each smoke installs a real guest in a throwaway `OPENVM_HOME` and exercises every feature. `OPENVM_SMOKE_KEEP=1` keeps the VM and logs for debugging.

While they run, the smokes use the Mac's clipboard, restoring plain text at the end, and play a test tone. Do not copy anything during a run. If something else is playing on the Mac, the sound step says the host check proved nothing.

Printing uses a stand-in for CUPS, so no paper is involved. Output from passing runs is in `docs/evidence`.

## UI snapshots

`Tests/OpenVMAppTests/SnapshotTests.swift` renders the VM list to a PNG and compares it with
the baselines in `Tests/OpenVMAppTests/Snapshots`. They are opt-in (`OPENVM_UI_SNAPSHOTS=1`),
because how text and controls draw depends on the macOS version, so a baseline recorded on one
Mac fails on another and on CI. After a deliberate change to a view, refresh them with
`OPENVM_UI_SNAPSHOTS=1 OPENVM_UI_RECORD=1 make test`, then open the PNGs and look at them
before committing: a baseline of a broken layout passes just as well.

## Formatting

`make format` formats Swift with `swift format` and C with `clang-format`, using `.swift-format` and `.clang-format`.

## End-to-end wizard tests

`Tests/OpenVMAppTests/WizardEndToEndTests.swift` runs the creation wizard's model against a real
`openvmd` on a throwaway home, and checks the cleanup on disk. They are opt-in:

```sh
OPENVM_E2E=1 make test                        # cancel a Linux install; cancel a Windows media build (about 10 s)
OPENVM_E2E_FULL=1 OPENVM_E2E=1 make test      # also install Linux from the wizard to the end (about 10 minutes)
```

They need the Linux files fetched, `make payload` run, and, for the Windows test, the ISO in
`windowsImage/`. They leave no files, mounts or processes behind.
