// A guest installed before the send op existed must get a sentence a person can act on.
import Testing

@testable import OpenVMHost

struct OldToolsTests {
    @Test func oldAgentReportsNeedsUpdate() {
        let raw = "guest drag failed: drag op must be enter, leave, drop or status"
        #expect(oldToolsHint(forSend: raw).contains("too old"))
    }

    @Test func otherFailuresAreLeftAlone() {
        let raw = "guest drag failed: send has no usable path"
        #expect(oldToolsHint(forSend: raw) == raw)
    }
}
