// AppSettingsModel — openVM's own settings (not a VM's): kept in the app's defaults, and published so
// the menu-bar icon and the library follow a change at once.
import Combine
import Foundation

@MainActor
final class AppSettingsModel: ObservableObject {
    static let shared = AppSettingsModel(defaults: .standard)

    private enum Key {
        static let menuBarIcon = "show-menu-bar-icon"
        static let previews = "show-previews"
    }

    private let defaults: UserDefaults

    /// The openVM icon at the right of the menu bar. On unless turned off.
    @Published var showsMenuBarIcon: Bool {
        didSet { defaults.set(showsMenuBarIcon, forKey: Key.menuBarIcon) }
    }
    /// Pictures of each VM's screen in the library. Off hides guest screens, for screen sharing.
    @Published var showsPreviews: Bool {
        didSet { defaults.set(showsPreviews, forKey: Key.previews) }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        showsMenuBarIcon = defaults.object(forKey: Key.menuBarIcon) as? Bool ?? true
        showsPreviews = defaults.object(forKey: Key.previews) as? Bool ?? true
    }
}
