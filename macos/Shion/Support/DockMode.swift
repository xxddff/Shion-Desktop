import AppKit
import Observation
import SwiftUI

/// Settings → 通用 → 关窗后只留在菜单栏, off unless you turn it on (then Shion behaves as before
/// it existed: the Dock icon stays). On, closing the last main window takes the Dock icon away
/// too (the accessory activation policy), and the count of what waits on you moves from the Dock
/// to the menu bar, next to 总秘书's mark (MenuBarCount). The icon comes back as soon as a main
/// window opens again: from the menu bar panel, a notification, a Shortcuts action or ⌘K's
/// pages. A preference, not a secret: kept in the defaults, except in screenshot and test runs,
/// which keep it in memory (`-ShionMenuBarOnly YES` turns it on there).
@Observable
final class DockMode {
    static let shared = DockMode()

    var menuBarOnly: Bool {
        didSet {
            guard menuBarOnly != oldValue else { return }
            if !LaunchOptions.current.snapshot {
                UserDefaults.standard.set(menuBarOnly, forKey: Self.key)
            }
            update()
        }
    }
    /// The Dock icon is away: the menu bar shows the count instead.
    private(set) var hidden = false

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    private static let key = "MenuBarOnly"

    private init() {
        menuBarOnly = LaunchOptions.current.snapshot
            ? UserDefaults.standard.bool(forKey: "ShionMenuBarOnly")
            : UserDefaults.standard.bool(forKey: Self.key)
    }

    /// Once the app has launched: follows the main windows from then on.
    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let window, Self.isMain(window) else { return }
                self?.update(closing: window)
            }
        })
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let window, Self.isMain(window) else { return }
                self?.update()
            }
        })
    }

    /// SwiftUI names the WindowGroup's windows `main-AppWindow-<n>`: not Settings, not the ⌥Space panel.
    static func isMain(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.contains("AppWindow") == true
    }

    /// The Dock icon is there while a main window is (or the option is off), away otherwise.
    private func update(closing: NSWindow? = nil) {
        // a minimized one is still open: it waits in the Dock
        let open = NSApp.windows.contains { window in
            window !== closing && Self.isMain(window) && (window.isVisible || window.isMiniaturized)
        }
        let hide = menuBarOnly && !open
        guard hide != hidden else { return }
        hidden = hide
        NSApp.setActivationPolicy(hide ? .accessory : .regular)
        if !hide && open {
            // the menu bar and the Dock icon come back with the app in front
            NSApp.activate()
        }
    }
}

/// What waits on you, next to 总秘书's mark in the menu bar, while the Dock icon (which shows it
/// otherwise) is away. The orange badge is drawn as an image that is not a template, so the menu
/// bar keeps its colour.
struct MenuBarCount: View {
    let count: Int

    var body: some View {
        if DockMode.shared.hidden && count > 0 {
            Image(nsImage: CountBadge.image(count))
                .renderingMode(.original)
                .accessibilityLabel("\(count) 件等你确认")
        }
    }
}

enum CountBadge {
    private static var made: [Int: NSImage] = [:]

    static func image(_ count: Int) -> NSImage {
        if let image = made[count] {
            return image
        }
        let renderer = ImageRenderer(content: CountBadgeMark(text: count > 99 ? "99+" : "\(count)"))
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage(size: NSSize(width: 16, height: 16))
        image.isTemplate = false
        made[count] = image
        return image
    }
}

/// The Dock's badge in small: the number in white on warm orange.
private struct CountBadgeMark: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .frame(minWidth: 16, minHeight: 15)
            .background(Capsule().fill(Palette.warm))
    }
}

/// The menu bar panel's way back to the main window while the Dock icon is away.
struct MenuBarOpenRow: View {
    var body: some View {
        if DockMode.shared.hidden {
            Button {
                MainWindow.show()
            } label: {
                PanelRow(systemImage: "macwindow", text: "打开 Shion") {
                    EmptyView()
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("menubar-open")
            .padding(.top, 4)
        }
    }
}
