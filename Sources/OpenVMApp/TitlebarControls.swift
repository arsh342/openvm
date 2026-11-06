// TitlebarControls — the few round buttons at the right of a VM window's title bar: power, pause,
// full screen and settings. They fade back when the pointer is away so the guest is what you look at,
// and the same commands are in the Machine menu. Which are live follows the VM (VMToolbarLogic).
import AppKit
import Combine
import SwiftUI

@MainActor
final class TitlebarControlsModel: ObservableObject {
    @Published var state = ToolbarState(power: .start, pause: .disabled, fullScreenEnabled: false)
    @Published var hovering = false
    var onPower: () -> Void = {}
    var onPause: () -> Void = {}
    var onFullScreen: () -> Void = {}
    var onSettings: () -> Void = {}
}

struct TitlebarControls: View {
    @ObservedObject var model: TitlebarControlsModel

    var body: some View {
        HStack(spacing: 8) {
            round(model.state.power.symbol, model.state.power.title, enabled: model.state.power != .disabled,
                  action: model.onPower)
            round(model.state.pause.symbol, model.state.pause.title, enabled: model.state.pause != .disabled,
                  action: model.onPause)
            round("arrow.up.left.and.arrow.down.right", "Full Screen", enabled: model.state.fullScreenEnabled,
                  action: model.onFullScreen)
            round("gearshape", "Settings", enabled: true, action: model.onSettings)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .opacity(model.hovering ? 1 : 0.45)
        .animation(.easeOut(duration: 0.15), value: model.hovering)
        .onHover { model.hovering = $0 }
    }

    private func round(_ symbol: String, _ help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(enabled ? 0.16 : 0.07)))
                .foregroundStyle(Color.white.opacity(enabled ? 0.95 : 0.35))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }
}
