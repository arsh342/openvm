# A Windows guest's size after it restarts itself, 2026-11-12

Guest: `win-lab`, Windows 11 ARM64 (26100), with `viogpudo` built from virtio-win pull request 1687 (the
mode-change fix, test-signed). The app gives a Windows guest the window's full size, here 2496x1440 at 2x.

## The fault

After a restart from Windows' Start menu the guest came back at 1024x768 and stayed there. Captures:
2496x1440 before, 1024x768 after.

* The VM keeps running through such a restart: `openvmctl list` showed it running throughout, so the app never
  sees the guest become ready again and never sizes it.
* The framework says nothing either. A `VZGraphicsDisplayObserver` on the VM's display logged only the app's own
  reconfigurations (1920x1080 at start, then 2496x1440), and nothing when the guest restarted. The display stayed
  configured at 2496x1440 while Windows ran at 1024x768.

## Windows refused every size after the restart

Asked from the Mac, Windows refused every size, small or large: 1280x800, 1536x864, 1920x1080, 2048x1152,
2496x1440, each with `DISP_CHANGE_BADMODE` (-2) from `ChangeDisplaySettingsEx`, while the driver listed sizes up
to 2936x1846. Setting the display back to 1920x1080 before the restart did not change that.

A WPP trace of `viogpudo` during one such request showed the display event arriving (`ConfigChanged`, the new
size added as the driver's custom mode), 240 `IsSupportedVidPn` calls and no `CommitVidPn`: Windows never asked
the driver to change mode, and no command to the device failed. A trace from the start of the boot showed the
driver's mode list: 640x480, 1024x768, and as the custom mode 5120x2880, the `PersistentDispMode0Width/Height`
values in the driver's key, which override the size the display reports (2048x1152 at that boot).

## What works

1. **Setting only the source mode.** `SetDisplayConfig` with the virtio path's source mode changed and
   `SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_ALLOW_CHANGES`, as virtio-win's own `viogpuap` does, took 2496x1440 at
   2x in the same stuck state, with no restart (capture 2496x1440). It succeeds only for a size the driver
   lists: right after a restart, with 2496x1440 not listed, it returned success and Windows stayed at 1024x768.
2. **Keeping the size listed.** With `PersistentDispMode0Width/Height` set to 2496x1440, the driver lists that
   size after a restart.

The agent now does both, and after a restart applies the last size the Mac asked for once someone is signed
in. From the agent's log, with a restart from the Start menu and nothing done by hand:

```
16:41:43 display: viogpudo will list 2496x1440 after a restart (was 5120x2880)
16:41:43 display holds 2496x1440 at scale 2 (2496x1440@2)
16:42:12 stopping
16:42:26 openvm-tools 1 starting (pid 3388)
16:42:33 display restored to 2496x1440 at scale 2 after a restart
```

Capture afterwards: 2496x1440. Not measured: why Windows refuses `ChangeDisplaySettingsEx` after a restart and
not after a cold start. In viogpudo's source, `AddSingleTargetMode` adds the mode at index `SourceId` on every
pass, so the monitor is offered one target mode; that may be the reason. Not tested with the released 0.1.302
driver, which cannot show any size but its first correctly anyway.

A side effect seen while testing: replacing the agent's file failed while its restore was retrying, because
each try runs a copy of the same executable in the user's session.
