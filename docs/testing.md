# Testing

| Command | Time | Needs |
| --- | --- | --- |
| `make check` | About a minute | Swift |
| `OPENVM_UI_SNAPSHOTS=1 make test` | About ten seconds more | Nothing extra |
| `tools/test/daemon-smoke.sh` | A few seconds | Nothing extra; boots no guest |
| `make windows-smoke ISO=<windows-iso>` | About 30 minutes | A Windows 11 ARM64 ISO, `zig`, and about 40 GB of disk; `wimlib` on the Mac, or the helper VM's files |

Run `make check` before every commit. Run the Windows smoke when a change touches a guest, the boot path or an install script.

## `make check`

| Suite | Proves |
| --- | --- |
| `Tests/OpenVMCoreTests` | The codec, registry and feature rules, including old Alpine records, and the helper VM's job script run against fake commands |
| `Tests/OpenVMDaemonTests` | Host policy: readiness, shutdown, the clock push, host sleep, host tasks, the host lock, the helper VM's endpoint and command line, outbox intake, and what `create` refuses |
| `Tests/OpenVMAppTests` | The app's models and menus without a window: the wizard, settings, the library, the clipboard rules, drops |
| `tools/test/test-*-agent` | Each Linux agent feature (kept for a later Linux guest; no guest installs it now), including hostile input, the Windows agent's build, codec, and hostile input to its drop parser, and `test-send-agent` for the guest send tool |
| `tools/test/conformance.sh` | Golden bytes through the mock guest |

Use `make test`, not `swift test`: with only the Command Line Tools installed, `swift test` cannot find the testing macros, and the Makefile names them.

The Windows agent's real build is checked only when `zig` is installed.

## Smokes

`tools/test/daemon-smoke.sh` runs the daemon and the CLI on a throwaway `OPENVM_HOME` with no guest: what `create` accepts and refuses, and how an Alpine VM from an earlier openVM is listed, refused at `start`, and deleted.

`make windows-smoke` installs a real Windows guest in a throwaway `OPENVM_HOME` and exercises every feature. `OPENVM_SMOKE_KEEP=1` keeps the VM and logs for debugging (both smokes).

While it runs, the Windows smoke uses the Mac's clipboard, restoring plain text at the end, and play a test tone. Do not copy anything during a run. If something else is playing on the Mac, the sound step says the host check proved nothing.

The Linux smoke that installed openVM's own Alpine guest is gone with that guest; its last runs are in `docs/evidence/linux-smoke-*`.

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
`openvmd` on a throwaway home, and checks the cleanup on disk. It is opt-in:

```sh
OPENVM_E2E=1 make test                        # cancel a Windows media build (about 10 s)
```

It needs `make payload` run and the ISO in `windowsImage/`. It leaves no files, mounts or processes
behind.
