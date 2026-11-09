import AppKit
import UserNotifications

/// System notifications for what wants you while its page is not in front of you: an approval or
/// a question, answered in the notification itself, and an assistant's reply, replied to the same
/// way. Clicking one opens the page it belongs to. Screenshot and test runs never start it.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Opens the main window when it was closed (set by a view that has `openWindow`).
    var openMainWindow: (() -> Void)?
    private weak var store: AppStore?

    private enum Category {
        static let reply = "reply"
        static let approval = "approval"
        static let question = "question"
    }

    /// The approval actions are named as Hermes names the choices, so they answer directly.
    private enum Action {
        static let reply = "reply"
        static let once = "once"
        static let deny = "deny"
        static let answer = "answer"
    }

    func start(_ store: AppStore) {
        guard self.store == nil else { return }
        self.store = store
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Category.reply,
                actions: [UNTextInputNotificationAction(identifier: Action.reply, title: "回复", options: [],
                                                        textInputButtonTitle: "发送", textInputPlaceholder: "")],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: Category.approval,
                actions: [
                    UNNotificationAction(identifier: Action.once, title: "允许这一次", options: []),
                    UNNotificationAction(identifier: Action.deny, title: "拒绝", options: [.destructive]),
                ],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: Category.question,
                actions: [UNTextInputNotificationAction(identifier: Action.answer, title: "回答", options: [],
                                                        textInputButtonTitle: "发送", textInputPlaceholder: "")],
                intentIdentifiers: []
            ),
        ])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// An approval or a question from `name`. One whose choices do not fit the notification's
    /// buttons (a question with options, an approval without once/deny) opens 等你确认 instead.
    func ask(_ ask: Ask, from name: String) {
        let content = UNMutableNotificationContent()
        let values = Set(ask.options.map(\.value))
        switch ask.kind {
        case .approval:
            content.title = "\(name) 等你批准"
            content.body = [ask.title, ask.preview].compactMap { $0 }.joined(separator: "\n")
            if values.contains(Action.once) && values.contains(Action.deny) {
                content.categoryIdentifier = Category.approval
            }
        case .clarify:
            content.title = "\(name) 问你"
            let choices = ask.options.map(\.label).filter { !$0.isEmpty && $0 != "跳过" }
            content.body = choices.isEmpty ? ask.title : "\(ask.title)\n\(choices.joined(separator: " / "))"
            if choices.isEmpty {
                content.categoryIdentifier = Category.question
            }
        default:
            content.title = name
            content.body = ask.title
        }
        content.userInfo = ["bot": ask.botId, "ask": ask.id]
        post(ask.id, content, thread: ask.botId)
    }

    /// An assistant's reply; a newer one from the same assistant takes its place.
    func reply(_ text: String, from name: String, botId: String) {
        let content = UNMutableNotificationContent()
        content.title = name
        content.body = text.count > 300 ? String(text.prefix(300)) + "…" : text
        content.categoryIdentifier = Category.reply
        content.userInfo = ["bot": botId]
        post("reply-\(botId)", content, thread: botId)
    }

    func withdraw(_ id: String) {
        guard store != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    func withdrawAll() {
        guard store != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()
    }

    private func post(_ id: String, _ content: UNMutableNotificationContent, thread: String) {
        guard store != nil else { return }
        content.sound = .default
        content.threadIdentifier = thread
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { _ in }
    }

    // MARK: answers from the notification

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.actionIdentifier
        let info = response.notification.request.content.userInfo
        let botId = info["bot"] as? String ?? ""
        let askId = info["ask"] as? String
        let text = (response as? UNTextInputNotificationResponse)?.userText ?? ""
        Task { @MainActor in
            self.handle(action: action, botId: botId, askId: askId, text: text)
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // posted only when its page is not in front, so it shows even while Shion is active
        completionHandler([.banner, .list, .sound])
    }

    private func handle(action: String, botId: String, askId: String?, text: String) {
        guard let store else { return }
        let pending = askId.flatMap { id in store.asks.first { $0.id == id } }
        switch action {
        case Action.reply:
            store.send(text, to: botId)
        case Action.once, Action.deny:
            if let pending, let option = pending.options.first(where: { $0.value == action }) {
                store.answer(pending, with: option)
            }
        case Action.answer:
            let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let pending, !answer.isEmpty {
                store.answer(pending, with: AskOption(value: answer, label: answer))
            }
        default:
            // clicked: the page it belongs to
            store.route = askId != nil ? .confirm : .chat(botId)
            bringToFront()
        }
    }

    private func bringToFront() {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("AppWindow") == true }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }
}
