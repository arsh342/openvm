# Sound in a Linux guest installed from its ISO, 2026-11-11

Guest: Omarchy 7.3 (Arch Linux ARM, Hyprland, PipeWire with WirePlumber 0.5.18), installed from its ISO in
`linux-vm`, on macOS 27.2. The guest's only sound card is Apple's virtio-sound device
(`VZVirtioSoundDeviceConfiguration` with a `VZHostAudioOutputStreamSink`), driven by the kernel's
virtio-snd driver.

## The fault

With the desktop's defaults the guest was silent, at 100% volume. During playback PipeWire held the card at
`period_size: 120` and `buffer_size: 1920` (2.5 ms periods, 40 ms buffer), in `FLOAT_LE`. On the Mac,
Core Audio listed `com.apple.Virtualization.VirtualMachine` as running output, but a Core Audio tap of all
system audio read a peak level of 0.0: the stream was open and every sample was zero.

## One variable at a time

Method: PipeWire paused, `aplay -D hw:0,0` playing a 2 ms click every 500 ms. As each click was handed
to `aplay`, the guest sent a UDP packet to the Mac, and a Core Audio tap on the Mac timed the click's arrival
in the output mix. Both times are on the Mac's clock. The owner listened as well.

| Samples | Period | Buffer | Clicks heard (tap) | Owner heard | Delay, median |
| --- | --- | --- | --- | --- | --- |
| 16-bit | 1024 (21 ms) | 4096 (85 ms) | 13/13 | yes | 137 ms |
| float | 1024 (21 ms) | 4096 (85 ms) | 13/13 | yes | 115 ms |
| 16-bit | 240 (5 ms) | 1920 | 0/12 | no | silent |
| float | 120 (2.5 ms) | 1920 | 0/12 | no | silent |
| 16-bit | 256 (5.3 ms) | 512 | 0/10 | | silent |
| 16-bit | 384 (8 ms) | 768 | 4/10 | | constant underruns |

A native Mac app (an AudioUnit at its default buffer) measured 13 ms by the same tap. With two-period
buffers `aplay` reported about 2,700 underruns across periods of 1024 down to 384, so those delays are not
counted. The sample format makes no difference; the period size does. Below about 5 ms the device plays
silence, and it needs a deeper buffer than two periods.

## The fix

`tools/guest/pipewire/51-openvm-sound.conf` in `~/.config/wireplumber/wireplumber.conf.d/`, then
`systemctl --user restart wireplumber pipewire pipewire-pulse`. During a `speaker-test` tone PipeWire held
`period_size: 512` and `buffer_size: 2048` (10.7 ms periods, 43 ms buffer), `FLOAT_LE`, and the owner heard
the tone. The delay with this setting was not measured.
