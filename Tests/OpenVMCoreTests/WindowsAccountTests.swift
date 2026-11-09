// The account a Windows guest is created with: what Windows will accept, and getting a password into
// the answer file without it being able to break the file or the script that fills it in.
import Foundation
import Testing

@testable import OpenVMCore

@Suite struct WindowsAccountTests {
    @Test func ordinaryNamesPass() {
        for name in ["arsh", "Arsh.Singh", "a_b-c", "x", String(repeating: "a", count: 20)] {
            #expect(WindowsAccount.nameProblem(name) == nil, "\(name)")
        }
    }

    @Test func namesWindowsRefusesAreCaught() {
        for name in ["", " ", "a b", "a/b", "a\\b", "a@b", "a:b", "a\"b", "dots.", "...", String(repeating: "a", count: 21)] {
            #expect(WindowsAccount.nameProblem(name) != nil, "\(name.debugDescription)")
        }
    }

    @Test func reservedNamesAreCaughtInAnyCase() {
        for name in ["Administrator", "administrator", "GUEST", "DefaultAccount", "WDAGUtilityAccount"] {
            #expect(WindowsAccount.nameProblem(name) != nil, "\(name)")
        }
    }

    /// Windows does not allow a user named like the computer, and a lookup of such a name can find the
    /// computer. That is what the old openvm/openvm pair did.
    @Test func theComputersNameIsRefused() {
        #expect(WindowsAccount.nameProblem(WindowsAccount.computerName) != nil)
        #expect(WindowsAccount.nameProblem(WindowsAccount.computerName.lowercased()) != nil)
        #expect(WindowsAccount.nameProblem("openvm") == nil)  // the default account is not the computer now
    }

    @Test func theComputerNameFitsWindowsLimit() {
        #expect(WindowsAccount.computerName.count <= 15)
    }

    @Test func aPasswordIsNeededAndMustMatch() {
        #expect(WindowsAccount.passwordProblem("", confirm: "") != nil)
        #expect(WindowsAccount.passwordProblem("secret", confirm: "secreT") != nil)
        #expect(WindowsAccount.passwordProblem("secret", confirm: "secret") == nil)
        #expect(WindowsAccount.passwordProblem("two words & more", confirm: "two words & more") == nil)
    }

    @Test func aPasswordThatCannotBeWrittenIsRefused() {
        #expect(WindowsAccount.passwordProblem("a\nb", confirm: "a\nb") != nil)
        #expect(WindowsAccount.passwordProblem("a\u{7}b", confirm: "a\u{7}b") != nil)
        let long = String(repeating: "a", count: 128)
        #expect(WindowsAccount.passwordProblem(long, confirm: long) != nil)
    }

    /// Runs the same `sed` the media script runs, then reads the XML back: what Windows would see.
    private func throughTheScript(_ password: String) throws -> String {
        let sed = Process()
        sed.executableURL = URL(fileURLWithPath: "/usr/bin/sed")
        sed.arguments = ["-e", "s|@PASSWORD@|\(WindowsAccount.templateValue(password))|g"]
        sed.environment = ["LC_ALL": "C"]
        let input = Pipe(), output = Pipe()
        sed.standardInput = input
        sed.standardOutput = output
        try sed.run()
        input.fileHandleForWriting.write(Data("<Value>@PASSWORD@</Value>\n".utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        sed.waitUntilExit()
        #expect(sed.terminationStatus == 0)
        let document = try XMLDocument(data: data)
        return try #require(document.rootElement()?.stringValue)
    }

    @Test func hostilePasswordsSurviveTheScriptAndTheXml() throws {
        for password in [
            "plain", "a&b", "a|b", "a\\b", "a/b", "<Value>", "]]>", "&amp;", "\\&", "\\\\", "a'b\"c", "$HOME", "`id`",
            "@USER@", "pa ss", "pässwörd", "パスワード", "%PATH%",
        ] {
            #expect(try throughTheScript(password) == password, "\(password)")
        }
    }
}
