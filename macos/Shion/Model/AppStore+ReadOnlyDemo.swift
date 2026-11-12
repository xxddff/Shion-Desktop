import Foundation

extension AppStore {
    /// The screenshot of the window while a dropped connection is being got back
    /// (`-ShionReadOnlyDemo YES`, with `-ShionReconnectDemo YES` for the sidebar's line): the
    /// demo's data, read-only, so what would change it (a card's answer and 让它继续 in 待你处理, a
    /// card's comment) is greyed out. The last data keeps no card questions (they can only be
    /// answered live), so this is the state they show greyed out in. Never outside screenshot runs.
    static var readOnlyDemo: Bool {
        LaunchOptions.current.snapshot && UserDefaults.standard.bool(forKey: "ShionReadOnlyDemo")
    }
}
