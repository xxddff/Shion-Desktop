import SwiftUI

@main
struct ShionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: AppStore
    @State private var jump = JumpState()

    init() {
        let store = AppStore(now: Clock.demoNow)
        _store = State(initialValue: store)
        // the ⌥Space window sends through the same store as the main window
        QuickAsk.shared.attach(store)
        // and so do Shortcuts, Spotlight and Siri (Intents/)
        ShionShortcuts.attach(store)
    }

    var body: some Scene {
        WindowGroup("Shion", id: "main") {
            RootView()
                // a notification's click lands here (Landing.swift); Siri learns the assistants
                .modifier(LandingRoot())
                .modifier(ShortcutsRoot())
                .environment(store)
                .environment(jump)
                .preferredColorScheme(LaunchOptions.current.colorScheme)
        }
        .defaultSize(width: 1240, height: 780)
        .commands {
            ShionCommands(store: store, jump: jump, quick: QuickAsk.shared)
        }

        MenuBarExtra {
            MenuBarPanel()
                .environment(store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsTabs()
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // the global shortcut goes live
        QuickAsk.shared.launched()
        // the Dock icon follows the main window when Settings say so (DockMode.swift)
        DockMode.shared.start()
        // test runs call the App Intents themselves (IntentHook.swift)
        IntentHook.start()
    }
}
