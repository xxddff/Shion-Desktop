import SwiftUI

@main
struct ShionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Screenshot runs pick the appearance for the whole app, so the menu bar panel follows too.
        if let scheme = LaunchOptions.current.colorScheme {
            NSApp.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        }
    }
}
