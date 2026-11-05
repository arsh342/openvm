// Tests for host printing rules.
import Foundation
import Testing

@testable import OpenVMCore

@Suite struct PrintingTests {
    @Test func destinationsAreOnePerLineSortedAndUnique() {
        let out = "Canon_MX920\nBrother-HL.2270\n\nCanon_MX920\n"
        #expect(Printing.parseDestinations(out) == ["Brother-HL.2270", "Canon_MX920"])
    }

    /// The name reaches a guest shell and PowerShell, so nothing with shell or
    /// path meaning may survive, whatever lpstat printed.
    @Test func unsafeDestinationsAreSkipped() {
        let out = "ok\nqueue/draft\nsemi;colon\n$(reboot)\nsp ace\n-rf\n.hidden\nq'uote\n"
        #expect(Printing.parseDestinations(out) == ["ok"])
    }

    @Test func defaultDestination() {
        #expect(Printing.parseDefault("system default destination: Canon_MX920\n") == "Canon_MX920")
        #expect(Printing.parseDefault("no system default destination\n") == nil)
        #expect(Printing.parseDefault("system default destination: a;b\n") == nil)
    }

    private func entry(_ job: String, _ printer: String, _ size: UInt64) -> CBOR {
        .map([("job", .text(job)), ("printer", .text(printer)), ("size", .uint(size))])
    }

    @Test func jobsParseAndHostilePathsAreDropped() {
        let reply = CBOR.map([
            (
                "jobs",
                .array([
                    entry("Canon--12.pdf", "Canon", 900),
                    entry("../../etc/passwd", "Canon", 900),
                    entry("/abs.pdf", "Canon", 900),
                    .text("not a map"),
                ])
            )
        ])
        #expect(
            Printing.parseJobs(reply) == [GuestPrintJob(job: "Canon--12.pdf", printer: "Canon", size: 900)])
    }

    @Test func noJobsKeyIsNoJobs() {
        #expect(Printing.parseJobs(.map([])).isEmpty)
        #expect(Printing.parseJobs(.text("x")).isEmpty)
    }

    /// A guest may only reach printers the host published to it.
    @Test func refusals() {
        let ok = GuestPrintJob(job: "a.pdf", printer: "Canon", size: 10)
        #expect(Printing.refusal(ok, allowed: ["Canon"]) == nil)
        #expect(Printing.refusal(ok, allowed: ["Other"]) != nil)
        #expect(
            Printing.refusal(GuestPrintJob(job: "a.pdf", printer: "Canon", size: 0), allowed: ["Canon"])
                != nil)
        let huge = GuestPrintJob(job: "a.pdf", printer: "Canon", size: Printing.maxJobBytes + 1)
        #expect(Printing.refusal(huge, allowed: ["Canon"]) != nil)
    }

    @Test func pdfMagic() {
        #expect(Printing.isPDF(Data("%PDF-1.7\n".utf8)))
        #expect(!Printing.isPDF(Data("%!PS-Adobe".utf8)))
        #expect(!Printing.isPDF(Data()))
    }

    @Test func aPendingSyncIsAskedAgain() {
        #expect(Printing.syncIsPending(.map([("pending", .bool(true))])))
        #expect(!Printing.syncIsPending(.map([("printers", .array([]))])))
        #expect(!Printing.syncIsPending(.map([("pending", .bool(false))])))
    }
}
