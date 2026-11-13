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
| `Tests/OpenVMAppTests` | The app's models and menus without a window: the one list of VM commands, the menu bar and which keys the Mac keeps, the library, the gallery and the wizard, failure messages, downloads, settings, the clipboard rules, drops |
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

`Tests/OpenVMAppTests/SnapshotTests.swift` renders each content view to a PNG, in light and in dark (`name.png`
and `name-dark.png`), and compares it with the baselines in `Tests/OpenVMAppTests/Snapshots`. A view is rendered
inside an offscreen window, after a turn of the run loop, because lists and tables make their rows only there.
Window chrome (toolbars, the sidebar's glass, menus, the icon) is not captured: only a person sees that.
The baselines were recorded on macOS 27. They are opt-in (`OPENVM_UI_SNAPSHOTS=1`),
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

## Installer downloads

`Tests/OpenVMDaemonTests/InstallerDownloadsTests.swift` runs the host's download job against a small HTTP
server the test starts on this Mac: a good download, a damaged one, a file the installer check refuses, a
missing file, a cut-off download picked up again, cancel and resume, a full disk, a second start, an index
that redirects to another host, and plain HTTP refused. The server is plain HTTP on 127.0.0.1, so each test
turns the HTTPS rule off for itself; the rule (HTTPS only, and the index from the vendor's own host) is tested
as a plain function in `Tests/OpenVMCoreTests/InstallerSourcesTests.swift`.

These tests wait with `Task.sleep`, never `Thread.sleep`: URLSession needs the threads the tests run on, and
tests that sleep on them stalled every download until they timed out (measured, with a sample of the process).
