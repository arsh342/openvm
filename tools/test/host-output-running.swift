// Prints whether the Mac's default output is running, for tools/test/windows-smoke.sh.
// `openvmctl audio status` cannot say during a tone: the Windows agent answers one
// request at a time, and it is busy playing.
import CoreAudio

var device = AudioObjectID(0)
var size = UInt32(MemoryLayout<AudioObjectID>.size)
var address = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
var running = UInt32(0)
size = UInt32(MemoryLayout<UInt32>.size)
address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running)
print(running != 0)
