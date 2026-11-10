import AppKit
import Observation
import ServiceManagement

/// Settings → 通用 → 开机启动: Shion as a login item of this Mac (`SMAppService.mainApp`). It is
/// off until you turn it on. The system keeps the state, and you can change it in System
/// Settings → 通用 → 登录项 too, so it is read again each time Shion comes to the front.
/// Screenshot and test runs never touch it: they keep a state of their own in memory, off unless
/// `-ShionLoginItemDemo requiresApproval` (or `on`) asks for another.
@Observable
final class LoginItem {
    static let shared = LoginItem()

    enum State: Equatable {
        case off
        case on
        /// Registered, and waiting for you to allow it in System Settings → 登录项.
        case needsApproval
        /// The system finds no login item for this copy of Shion.
        case notFound
    }

    private(set) var state: State = .off
    /// Why the last change did not go through, in the system's words.
    private(set) var failure: String?

    private let demo = LaunchOptions.current.snapshot
    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    private init() {
        guard !demo else {
            switch UserDefaults.standard.string(forKey: "ShionLoginItemDemo") {
            case "requiresApproval": state = .needsApproval
            case "on": state = .on
            default: state = .off
            }
            return
        }
        refresh()
        // allowed or turned off in System Settings meanwhile
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    /// Asked for: on, or waiting for your approval.
    var isOn: Bool { state == .on || state == .needsApproval }

    func refresh() {
        guard !demo else { return }
        state = Self.state(SMAppService.mainApp.status)
    }

    func set(_ on: Bool) {
        failure = nil
        guard !demo else {
            state = on ? .on : .off
            return
        }
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            failure = error.localizedDescription
        }
        refresh()
    }

    /// System Settings → 通用 → 登录项, where a login item waiting for approval is allowed.
    func openLoginItems() {
        guard !demo else { return }
        SMAppService.openSystemSettingsLoginItems()
    }

    private static func state(_ status: SMAppService.Status) -> State {
        switch status {
        case .enabled: .on
        case .requiresApproval: .needsApproval
        case .notFound: .notFound
        case .notRegistered: .off
        @unknown default: .off
        }
    }
}
