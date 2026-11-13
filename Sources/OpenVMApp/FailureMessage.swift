// FailureMessage — every failure a person can meet, in plain words: a title, one sentence, one thing to
// do, and the technical text behind Details. The host names a known failure with a code, and this maps
// codes, never sentences; anything else is "Something went wrong" with the host's text as its details.
import Foundation

struct FailureMessage: Equatable {
    /// The one thing offered to put it right.
    enum Action: Equatable {
        case chooseAnotherFile
        case getWindows
        case downloadAgain
        case openPage(URL)
        case tryAgain

        var label: String {
            switch self {
            case .chooseAnotherFile: return "Choose Another File…"
            case .getWindows: return "Get Windows from Microsoft"
            case .downloadAgain: return "Download Again"
            case .openPage: return "Open the Download Page"
            case .tryAgain: return "Try Again"
            }
        }
    }

    let title: String
    let sentence: String
    let action: Action?
    /// What the host or the tool said, for someone who wants it. Shown behind Details, and can be copied.
    let details: String

    /// The codes the host sends, and that this knows how to say.
    static let knownCodes = [
        "not-an-iso", "iso-incomplete", "linux-intel", "windows-intel", "windows-no-image", "not-windows",
        "download-failed", "download-damaged", "no-space", "installer-not-found", "helper-download-failed",
        "install-unfinished",
    ]

    static func of(code: String?, details: String, page: URL? = nil) -> FailureMessage {
        switch code {
        case "not-an-iso":
            return FailureMessage(
                title: "This is not an installer file",
                sentence: "openVM installs from a disc image, a file whose name ends in .iso.",
                action: .chooseAnotherFile, details: details)
        case "iso-incomplete":
            return FailureMessage(
                title: "This file is incomplete",
                sentence: "The download probably stopped early. Download it again.",
                action: .chooseAnotherFile, details: details)
        case "linux-intel":
            return FailureMessage(
                title: "This file is for Intel PCs",
                sentence:
                    "A Mac with Apple silicon needs the version for Arm, often called ARM64 or aarch64.",
                action: .chooseAnotherFile, details: details)
        case "windows-intel":
            return FailureMessage(
                title: "This Windows is for Intel PCs",
                sentence:
                    "A Mac with Apple silicon needs Windows 11 for Arm, which Microsoft offers on its own page.",
                action: .getWindows, details: details)
        case "windows-no-image", "not-windows":
            return FailureMessage(
                title: "This is not a Windows 11 installer openVM can use",
                sentence: "Use the Windows 11 for Arm file exactly as Microsoft’s page gives it.",
                action: .getWindows,
                details: details)
        case "download-failed":
            return FailureMessage(
                title: "The download did not finish",
                sentence: "Check the internet connection and try again.",
                action: .downloadAgain, details: details)
        case "download-damaged":
            return FailureMessage(
                title: "The download was damaged",
                sentence: "The file did not match the one its maker published, so openVM removed it.",
                action: .downloadAgain, details: details)
        case "no-space":
            return FailureMessage(
                title: "Not enough free space", sentence: "Free some space on this Mac, then try again.",
                action: .tryAgain, details: details)
        case "installer-not-found":
            return FailureMessage(
                title: "The installer could not be found",
                sentence:
                    "Its maker may have published a new version. You can download it from their page instead.",
                action: page.map(Action.openPage), details: details)
        case "helper-download-failed":
            return FailureMessage(
                title: "The helper download did not finish",
                sentence: "Check the internet connection and try again.",
                action: .tryAgain, details: details)
        case "install-unfinished":
            return FailureMessage(
                title: "The installation did not finish",
                sentence:
                    "The virtual machine was created and is still there. You can open it, or delete it and start again.",
                action: nil, details: details)
        default:
            return FailureMessage(
                title: "Something went wrong",
                sentence: "openVM could not finish this. The details say what happened.",
                action: nil, details: details)
        }
    }
}
