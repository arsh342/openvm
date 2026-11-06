// The helper VM that runs a job inside Alpine: how it boots, and how its result is read.
import Foundation
import Testing

@testable import OpenVMHost

struct WimHelperVMTests {
    @Test func jobBootCarriesTheJobArg() {
        let line = WimHelperVM.commandLine(artifactPort: 51234, modloopPinned: true, environment: [:])
        #expect(line.contains("openvm.job=wim"))
        // it fetches the overlay and the modules from the helper's own endpoint, not port 8124
        #expect(line.contains("apkovl=http://192.168.64.1:51234/openvm.apkovl.tar.gz"))
        #expect(line.contains("modloop=http://192.168.64.1:51234/modloop-virt"))
        #expect(!line.contains("openvm.install=1"))  // it is not installing a guest
        #expect(!line.contains("openvm.artifact-token"))
    }

    @Test func aJobThatReportedOkSucceeds() {
        #expect(interpretJobStatus("ok\n", consoleTail: "") == nil)
        #expect(interpretJobStatus("ok", consoleTail: "") == nil)
    }

    @Test func aJobThatReportedAnErrorFails() {
        let error = interpretJobStatus("error: could not install wimlib; the Mac needs to be online\n", consoleTail: "")
        #expect(error?.description.contains("could not install wimlib") == true)
    }

    /// The VM stopped and wrote nothing: the folder could not be mounted, or the guest crashed.
    /// The console is the only evidence, so it travels with the error.
    @Test func noStatusIsNotSuccess() {
        for text in [nil, "", "   \n"] as [String?] {
            let error = interpretJobStatus(text, consoleTail: "kernel panic")
            #expect(error != nil)
            #expect(error?.description.contains("kernel panic") == true)
        }
    }

    @Test func anythingElseInTheStatusFileIsNotSuccess() {
        #expect(interpretJobStatus("okay then", consoleTail: "") != nil)
        #expect(interpretJobStatus("ok but not really\nerror: x", consoleTail: "") != nil)
    }

    @Test func theGuestMemoryIsEnoughForWimlibAndItsFiles() {
        #expect(WimHelperVM.memoryMB >= 2048)
    }
}
