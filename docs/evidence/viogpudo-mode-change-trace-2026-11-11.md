# viogpudo's mode change, traced on Apple's virtio-gpu device, 2026-11-11

Guest `win-lab`: Windows 11 ARM64 (26100), Red Hat VirtIO GPU DOD controller 100.103.104.30200
(virtio-win 0.1.302, the attestation-signed release), no Test Mode. macOS 27.2.

## Method

The release `viogpudo.sys` logs through WPP, provider `{D6B96B2C-72BF-4CA5-BB89-9FCA5C82F020}`. Every
control-queue reply other than OK is logged with its type and the command it answered
(`viogpudo.cpp:3798` in this build), and any error reply also as "Command failed" (`:3787`).

1. In the guest, as administrator: `logman start viogpu -p "{D6B96B2C-72BF-4CA5-BB89-9FCA5C82F020}"
   0xffffffff 5 -o C:\openvm\viogpu.etl -ets`.
2. On the Mac, `openvmctl display set win-lab` stepped through 1024x768, 1536x864, 1024x768, 1280x800,
   1024x768, 1600x900, 1024x768, 2048x1152, 1024x768, 8 s apart. The guest confirmed every mode.
3. `logman stop`, then `tracerpt -tp <tmf>` decoded the trace in the guest. The TMF message formats came
   from the `viogpudo.pdb` shipped on the virtio-win 0.1.302 ISO (`w11/ARM64`), read on the Mac with
   `llvm-pdbutil dump -symbols` (427 messages).

## What the device answered

The same at every one of the eight changes. Times are UTC; repeated lines are collapsed.

```
03:41:31.709   PutId 1
03:41:31.709   GetId 1
03:41:31.709 MODE 1536x864
03:41:31.712   UNREF -> ERR_INVALID_PARAMETER
03:41:31.712   CREATE_2D -> ERR_INVALID_RESOURCE_ID
03:41:31.713   SET_SCANOUT -> ERR_INVALID_PARAMETER
03:41:31.713   TRANSFER_2D -> ERR_INVALID_PARAMETER   (x41)
03:41:40.956   PutId 1
03:41:40.956   GetId 1
03:41:40.956   UNREF -> ERR_INVALID_PARAMETER
03:41:40.956   CREATE_2D -> ERR_INVALID_RESOURCE_ID
03:41:40.956 MODE 1024x768
```

1280x800, 1600x900 and 2048x1152 gave the same four refusals (40, 41 and 56 refused transfers), and
every return to 1024x768 gave the first two only. `DETACH_BACKING` and `ATTACH_BACKING` were never
refused. 198 "Command failed" lines in all.

## Reading

* `DestroyFrameBufferObj(FALSE, FALSE)` unrefs the resource while it is still the scanout's resource,
  and Apple's device refuses that (`ERR_INVALID_PARAMETER`).
* `CreateFrameBufferObj` then creates the new mode under the same id, because the id went straight back
  through the free list, and the device refuses it as a resource that exists (`ERR_INVALID_RESOURCE_ID`).
* The resource on screen therefore stays the one made at boot, 1024x768, with the new mode's memory
  attached as its backing. Scanouts and transfers larger than 1024x768 are refused. The device reads the
  new, wider memory at 1024 pixels a row, which is the scramble in `docs/gui-notes.md`. A 1024-wide mode
  fits the old resource, which is why it is the only clean width.
* QEMU's virtio-gpu takes an unref of a scanned-out resource, so the driver works there. Not tested here.

A change that works on both: create the new mode under a fresh id, point the scanout at it, then detach
and unref the old resource. Not built or tested yet.

## The fix, built and traced (2026-11-12)

Reported upstream as virtio-win issue 1720. The change is `docs/patches/viogpudo-mode-change.patch`, against
virtio-win master (`2775c3d`): in `SetCurrentMode`, detach the old resource's backing, create the new mode
under a fresh id and point the scanout at it, and only then unref the old resource and return its id.

Built in `win-lab` with the Windows 11 24H2 EWDK (26100), `Win11 Release|ARM64`: 0 errors, 0 warnings.
Signed with virtio-win's test certificate and loaded under Test Mode by pointing the `VioGpuDod` service's
`ImagePath` at it and restarting (no live device stop).

The same nine-mode sequence, traced the same way:

| | 0.1.302 | with the change |
| --- | --- | --- |
| "Command failed" lines | 198 | 0 |
| Refused replies | UNREF, CREATE_2D, SET_SCANOUT, TRANSFER_2D at every change | none |
| Resource ids | 1 reused every time | 1 and 2 alternating |

```
03:42:33.505   GetId 2
03:42:33.505   PutId 1
03:42:33.505 MODE 1536x864
03:42:42.755   GetId 1
03:42:42.755   PutId 2
03:42:42.755 MODE 1024x768
```

The guest confirmed every mode (1536x864, 1280x800, 1600x900, 2048x1152), and the owner, watching the window
through the run, saw a correct picture at every size. The app's Mac-side capture of the window was a clean
desktop at 1600x900 (black with the earlier one-byte patch) and at 2560x1600 with 2x scale, a Retina size.
Not tested: QEMU, and a mode change that fails part way.
