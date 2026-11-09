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
    private var onStart: (() -> Void)?

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

        let stack = NSStackView(views: [spinner, label, detail, button])
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
    func show(_ state: VMWindowState, onStart: @escaping () -> Void) {
        self.onStart = onStart
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
        case .failed(let why):
            isHidden = false
            label.stringValue = "Something is wrong"
            detail.stringValue = why
        }
    }

    @objc private func startPressed() { onStart?() }
}
