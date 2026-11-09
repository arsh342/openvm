// HostAudio — the Mac's side of guest sound. The framework plays a guest's stream to
// the default output, so whether that device is running is the host's own evidence
// that a guest is being heard. It is only evidence: any other app can run it too.
import CoreAudio
import Foundation
import Virtualization

nonisolated enum HostAudio {
    /// A guest's sound card, playing to the Mac's default output.
    static func device() -> VZVirtioSoundDeviceConfiguration {
        let stream = VZVirtioSoundDeviceOutputStreamConfiguration()
        stream.sink = VZHostAudioOutputStreamSink()
        let device = VZVirtioSoundDeviceConfiguration()
        device.streams = [stream]
        return device
    }

    static func outputIsRunning() -> Bool {
        var output = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                &size, &output) == noErr
        else { return false }
        var running = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        guard AudioObjectGetPropertyData(output, &address, 0, nil, &size, &running) == noErr else {
            return false
        }
        return running != 0
    }
}
