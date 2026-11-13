// TitlebarControls — the few round buttons at the right of a VM window's title bar: power, pause,
// full screen and settings. They fade back when the pointer is away so the guest is what you look at.
// What each says and whether it is live comes from the one list of commands (VMCommand).
import AppKit
import Combine
import SwiftUI

@MainActor
final class TitlebarControlsModel: ObservableObject {
    @Published var power = VMCommand.power.state(for: nil)
    @Published var pause = VMCommand.pause.state(for: nil)
    @Published var settings = VMCommand.settings.state(for: nil)
    @Published var hovering = false
    var run: (VMCommand) -> Void = { _ in }
    var onFullScreen: () -> Void = {}
}

struct TitlebarControls: View {
    @ObservedObject var model: TitlebarControlsModel

    var body: some View {
        HStack(spacing: 8) {
            round(model.power) { model.run(.power) }
            round(model.pause) { model.run(.pause) }
            round(
                VMCommandState(title: "Full Screen", symbol: "arrow.up.left.and.arrow.down.right", enabled: true),
                action: model.onFullScreen)
            round(model.settings) { model.run(.settings) }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .opacity(model.hovering ? 1 : 0.45)
        .animation(.easeOut(duration: 0.15), value: model.hovering)
        .onHover { model.hovering = $0 }
    }

    private func round(_ state: VMCommandState, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: state.symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(state.enabled ? 0.16 : 0.07)))
                .foregroundStyle(Color.white.opacity(state.enabled ? 0.95 : 0.35))
        }
        .buttonStyle(.plain)
        .disabled(!state.enabled)
        .help(state.title.replacingOccurrences(of: "…", with: ""))
        .accessibilityLabel(state.title.replacingOccurrences(of: "…", with: ""))
    }
}
