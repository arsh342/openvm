// openVM's own settings: what they are before anyone changes them, and that a change is kept.
import Foundation
import Testing

@testable import OpenVMApp

@MainActor
struct AppSettingsModelTests {
    private func defaults() -> UserDefaults {
        let name = "openvm-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func bothAreOnUntilTurnedOff() {
        let model = AppSettingsModel(defaults: defaults())
        #expect(model.showsMenuBarIcon)
        #expect(model.showsPreviews)
    }

    @Test func aChangeIsKeptForTheNextLaunch() {
        let store = defaults()
        let model = AppSettingsModel(defaults: store)
        model.showsMenuBarIcon = false
        model.showsPreviews = false
        let next = AppSettingsModel(defaults: store)
        #expect(!next.showsMenuBarIcon)
        #expect(!next.showsPreviews)
        next.showsMenuBarIcon = true
        #expect(AppSettingsModel(defaults: store).showsMenuBarIcon)
    }
}
