import SwiftUI

@main
struct ShionApp: App {
    @State private var store = AppStore(now: Clock.demoNow)

    var body: some Scene {
        WindowGroup("Shion") {
            RootView()
                .environment(store)
                .preferredColorScheme(LaunchOptions.current.colorScheme)
        }
        .defaultSize(width: 1240, height: 780)

        MenuBarExtra {
            MenuBarPanel()
                .environment(store)
                .preferredColorScheme(LaunchOptions.current.colorScheme)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(store)
                .preferredColorScheme(LaunchOptions.current.colorScheme)
        }
    }
}
