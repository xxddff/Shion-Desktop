import AppKit
import ApplicationServices
import EventKit
import UniformTypeIdentifiers

// The real sources of local data: EventKit for the calendars, NSWorkspace and Accessibility for
// the window in front. LocalSources.swift has what they promise and the made-up ones that
// screenshots and tests use instead.

final class EventKitCalendars: CalendarSource {
    private let store = EKEventStore()
    var onChange: (() -> Void)?

    init() {
        _ = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onChange?()
            }
        }
    }

    var access: CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied  // denied, restricted, or only allowed to add events
        }
    }

    func requestAccess() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // EventKit answers on a queue of its own
            store.requestFullAccessToEvents { @Sendable _, _ in
                continuation.resume()
            }
        }
    }

    func calendars() -> [CalendarInfo] {
        store.calendars(for: .event).map { calendar in
            // EventKit's headers leave these unspecified: read them as optionals
            let source: EKSource? = calendar.source
            let base: NSColor? = calendar.color
            let srgb: NSColor? = base?.usingColorSpace(.sRGB)
            let color: CalendarColor = srgb.map {
                .rgb(red: Double($0.redComponent), green: Double($0.greenComponent), blue: Double($0.blueComponent))
            } ?? .hue(0)
            let title: String? = calendar.title
            return CalendarInfo(
                id: calendar.calendarIdentifier,
                title: title ?? "",
                account: source?.title ?? "",
                color: color,
                preselected: calendar.type != .birthday && calendar.type != .subscription
            )
        }
    }

    func items(from start: Date, to end: Date, in ids: Set<String>) -> [CalendarItem] {
        let chosen = store.calendars(for: .event).filter { ids.contains($0.calendarIdentifier) }
        guard !chosen.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: chosen)
        return store.events(matching: predicate).compactMap(Self.item(from:))
    }

    private static func item(from event: EKEvent) -> CalendarItem? {
        let startDate: Date? = event.startDate
        let endDate: Date? = event.endDate
        let owner: EKCalendar? = event.calendar
        guard let start = startDate, let end = endDate, let owner else { return nil }
        let identifier: String? = event.eventIdentifier
        let title: String? = event.title
        let location: String? = event.location
        let place = location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return CalendarItem(
            id: "\(identifier ?? event.calendarItemIdentifier)@\(Int(start.timeIntervalSince1970))",
            calendarId: owner.calendarIdentifier,
            title: title ?? "",
            start: start,
            end: max(start, end),
            allDay: event.isAllDay,
            place: place.isEmpty ? nil : place
        )
    }
}

final class WorkspaceFront: FrontSource {
    var onChange: (() -> Void)?
    private var locked = false
    private var asleep = false
    private var asked = false

    init() {
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didActivateApplicationNotification)
        observe(workspace, NSWorkspace.screensDidSleepNotification, asleep: true)
        observe(workspace, NSWorkspace.screensDidWakeNotification, asleep: false)
        observe(workspace, NSWorkspace.willSleepNotification, asleep: true)
        observe(workspace, NSWorkspace.didWakeNotification, asleep: false)
        let screen = DistributedNotificationCenter.default()
        observe(screen, Notification.Name("com.apple.screenIsLocked"), locked: true)
        observe(screen, Notification.Name("com.apple.screenIsUnlocked"), locked: false)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, asleep: Bool? = nil, locked: Bool? = nil) {
        _ = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let asleep { self.asleep = asleep }
                if let locked { self.locked = locked }
                self.onChange?()
            }
        }
    }

    func look(titles: Bool) async -> FrontWindow? {
        guard !locked, !asleep, let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let bundleId = app.bundleIdentifier ?? ""
        // the lock screen and the screen saver are not an app you use
        guard bundleId != "com.apple.loginwindow", bundleId != "com.apple.ScreenSaver.Engine" else { return nil }
        var front = FrontWindow(bundleId: bundleId, app: app.localizedName ?? bundleId)
        if titles, AXIsProcessTrusted() {
            let pid = app.processIdentifier
            // a hung app can hold an Accessibility call: not on the main thread
            front.title = await Task.detached(priority: .utility) { WindowTitle.focused(of: pid) }.value ?? ""
        }
        return front
    }

    var idleSeconds: TimeInterval {
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    var titlesAllowed: Bool { AXIsProcessTrusted() }

    func askForTitles() {
        guard !AXIsProcessTrusted() else { return }
        if !asked {
            asked = true
            // the system's prompt, which leads to System Settings (the key is kAXTrustedCheckOptionPrompt's value)
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        } else {
            MacLocal.openPrivacy("Privacy_Accessibility")
        }
    }
}

/// The title of an app's focused window, read through Accessibility.
nonisolated enum WindowTitle {
    static func focused(of pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(app, 0.5)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXFocusedWindow" as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(unsafeDowncast(window, to: AXUIElement.self), "AXTitle" as CFString, &title) == .success,
              let text = title as? String
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(300))
    }
}

/// The few AppKit calls the local data needs.
enum MacLocal {
    /// A pane of Privacy & Security in System Settings: `Privacy_Calendars`, `Privacy_Accessibility`.
    static func openPrivacy(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        _ = NSWorkspace.shared.open(url)
    }

    /// Runs `body` as the app quits.
    static func onQuit(_ body: @escaping @MainActor @Sendable () -> Void) {
        _ = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                body()
            }
        }
    }

    /// The app's icon, for the list of excluded apps.
    static func icon(_ bundleId: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    /// Picks an app in /Applications to leave out of the record.
    static func chooseApp() -> ExcludedApp? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url),
              let bundleId = bundle.bundleIdentifier
        else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return ExcludedApp(bundleId: bundleId, name: name)
    }
}
