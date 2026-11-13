// Every failure a person can meet has a plain title, one sentence and one action, with the technical
// text kept for Details.
import Foundation
import Testing

@testable import OpenVMApp

struct FailureMessageTests {
    @Test func everyKnownCodeHasItsOwnPlainWords() {
        let generic = FailureMessage.of(code: nil, details: "x")
        for code in FailureMessage.knownCodes {
            let failure = FailureMessage.of(
                code: code, details: "raw text from the host", page: URL(string: "https://example.org")!)
            #expect(failure.title != generic.title, "\(code) has no words of its own")
            #expect(!failure.sentence.isEmpty, "\(code)")
            #expect(failure.details == "raw text from the host", "\(code)")
            // One sentence, not a paragraph.
            #expect(failure.sentence.count < 140, "\(code): \(failure.sentence)")
        }
    }

    /// The words a newcomer would trip on stay out of titles and sentences. The wrong-file failures may
    /// name the right kind, because that is what to look for on a download page.
    @Test func titlesAndSentencesAvoidTechnicalWords() {
        for code in FailureMessage.knownCodes {
            let failure = FailureMessage.of(code: code, details: "")
            let text = (failure.title + " " + failure.sentence).lowercased()
            for word in ["uefi", "wimlib", "x86", "boot readiness", "console", "test-signed", "sha"] {
                #expect(!text.contains(word), "\(code) says \(word)")
            }
        }
    }

    @Test func anUnknownFailureKeepsTheHostsTextForDetails() {
        let failure = FailureMessage.of(
            code: "something-new", details: "guest did not reach boot readiness… console tail")
        #expect(failure.title == "Something went wrong")
        #expect(failure.details.contains("console tail"))
        #expect(failure.action == nil)
    }

    @Test func theActionFitsTheFailure() {
        #expect(FailureMessage.of(code: "linux-intel", details: "").action == .chooseAnotherFile)
        #expect(FailureMessage.of(code: "windows-intel", details: "").action == .getWindows)
        #expect(FailureMessage.of(code: "download-damaged", details: "").action == .downloadAgain)
        let page = URL(string: "https://ubuntu.com/download/desktop")!
        #expect(
            FailureMessage.of(code: "installer-not-found", details: "", page: page).action == .openPage(page))
        #expect(FailureMessage.of(code: "installer-not-found", details: "").action == nil)
    }
}
