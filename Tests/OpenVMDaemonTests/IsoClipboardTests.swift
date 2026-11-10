// The clipboard for a guest installed from its own ISO: the framework's Spice agent port, present only
// when the VM's clipboard setting is on.
import Testing
import Virtualization

@testable import OpenVMHost

@MainActor
struct IsoClipboardTests {
    @Test func theSpiceAgentPortIsThereOnlyWhenAsked() throws {
        guard #available(macOS 13.0, *) else { return }
        #expect(GuestLinuxISO.clipboardConsoles(shared: false).isEmpty)
        let consoles = GuestLinuxISO.clipboardConsoles(shared: true)
        #expect(consoles.count == 1)
        let device = try #require(consoles.first as? VZVirtioConsoleDeviceConfiguration)
        let port = try #require(device.ports[0])
        #expect(port.name == VZSpiceAgentPortAttachment.spiceAgentPortName)
        let attachment = try #require(port.attachment as? VZSpiceAgentPortAttachment)
        #expect(attachment.sharesClipboard)
    }
}
