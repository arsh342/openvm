// VMStatusView — what covers the screen when there is no guest to show: a stopped VM,
// a fault, or a short message. It sits over the machine view and is hidden while the
// guest draws.
import AppKit

@MainActor
final class VMStatusView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let button = NSButton(title: "Start", target: nil, action: nil)
    private let removeInstaller = NSButton(title: "Remove Installer and Start", target: nil, action: nil)
    private var onStart: (() -> Void)?
    private var onRemoveInstaller: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        label.font = .systemFont(ofSize: 20, weight: .medium)
        label.alignment = .center
        detail.alignment = .center
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 4
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isIndeterminate = true
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"
        button.target = self
        button.action = #selector(startPressed)
        removeInstaller.bezelStyle = .rounded
        removeInstaller.target = self
        removeInstaller.action = #selector(removeInstallerPressed)

        let buttons = NSStackView(views: [removeInstaller, button])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        let stack = NSStackView(views: [spinner, label, detail, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows the cover for a state, or hides it when the guest's screen is on show.
    /// `installerAttached` is a Linux VM that still has its installer: once the system is installed, the
    /// installer's own "Restart now" stops the VM here, and one button removes the installer and starts it.
    func show(
        _ state: VMWindowState, installerAttached: Bool = false, onStart: @escaping () -> Void,
        onRemoveInstaller: @escaping () -> Void = {}
    ) {
        self.onStart = onStart
        self.onRemoveInstaller = onRemoveInstaller
        removeInstaller.isHidden = true
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        button.isHidden = true
        detail.stringValue = ""
        switch state {
        case .running, .paused, .busy:
            isHidden = true
        case .stopped:
            isHidden = false
            label.stringValue = "This VM is stopped"
            button.isHidden = false
            if installerAttached {
                removeInstaller.isHidden = false
                detail.stringValue = Self.installerNote
            }
        case .failed(let why):
            isHidden = false
            label.stringValue = "Something is wrong"
            detail.stringValue = why
        }
    }

    /// What a stopped VM with its installer still attached says.
    static let installerNote =
        "The installer is still attached. If the system is installed, remove the installer so the VM starts from its disk. If not, press Start to go on installing."

    @objc private func startPressed() { onStart?() }
    @objc private func removeInstallerPressed() { onRemoveInstaller?() }

    /// Whether the installer button is offered, for tests.
    var offersRemoveInstaller: Bool { !isHidden && !removeInstaller.isHidden }
}
