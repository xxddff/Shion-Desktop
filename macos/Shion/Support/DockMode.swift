import AppKit
import Observation
import SwiftUI

/// Settings → 这台 Mac → 关窗后只留在菜单栏, off unless you turn it on (then Shion behaves as before
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

    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
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
/// otherwise) is away: the number cut out of a small filled capsule after the mark. A status item
/// shows one image and one text, so the mark and the count are one image, a template like the
/// mark alone, which the menu bar tints for its light or dark look.
enum MenuBarCount {
    private static var made: [String: NSImage] = [:]

    /// The status item's image: the mark, with the count while the Dock icon is away.
    static func icon(_ initial: String, count: Int) -> NSImage {
        guard DockMode.shared.hidden && count > 0 else {
            return MenuBarIcon.image(initial)
        }
        let text = count > 99 ? "99+" : "\(count)"
        let key = "\(initial)|\(text)"
        if let image = made[key] {
            return image
        }
        let renderer = ImageRenderer(content: CountedMark(mark: MenuBarIcon.image(initial), text: text))
        renderer.scale = 2
        guard let image = renderer.nsImage else {
            return MenuBarIcon.image(initial)
        }
        image.isTemplate = true
        image.accessibilityDescription = "\(count) 件等你确认"
        made[key] = image
        return image
    }
}

/// The mark, then the count: the digits are cut out of the capsule (drawn into it with
/// destination-out), so they show the menu bar through them.
private struct CountedMark: View {
    let mark: NSImage
    let text: String

    var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: mark)
            Text(text)
                .font(.system(size: 9.5, weight: .bold))
                .monospacedDigit()
                .blendMode(.destinationOut)
                .padding(.horizontal, 3.5)
                .frame(minWidth: 15, minHeight: 13)
                .background(Capsule().fill(.foreground))
                .compositingGroup()
        }
    }
}

/// The menu bar panel's way back to the main window while the Dock icon is away, with the line
/// the window's sidebar has under the server (ConnectionFooter: the connection being got back, or
/// the last data and from when), which nothing else shows while the window is closed.
struct MenuBarOpenRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if DockMode.shared.hidden {
            Button {
                // the panel closes, the window comes in front of where it was
                dismiss()
                MainWindow.show()
            } label: {
                PanelRow(systemImage: "macwindow", text: "打开 Shion") {
                    if let note = store.reconnectNote ?? store.lastDataNote {
                        Text(note)
                            .font(.t11)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .accessibilityIdentifier("menubar-connection-note")
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("menubar-open")
            .padding(.top, 4)
        }
    }
}
