// AppSettingsView — the app's Settings window (openVM ▸ Settings…, Command-comma). A VM's own settings
// are in its Settings window, under Virtual Machine ▸ Settings….
import SwiftUI

struct AppSettingsView: View {
    @ObservedObject var model: AppSettingsModel

    var body: some View {
        Form {
            Section {
                Toggle("Show openVM in the menu bar", isOn: $model.showsMenuBarIcon)
                Text("The icon keeps running virtual machines within reach when every window is closed. With it off, openVM stays in the Dock instead.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle("Show previews of virtual machines in the library", isOn: $model.showsPreviews)
                Text("A preview is the last picture taken of a virtual machine's screen. Turn this off to keep guest screens out of the library, for example while sharing your screen.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}
