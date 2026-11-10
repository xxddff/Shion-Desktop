import AppKit
import UserNotifications

/// System notifications for what wants you while its page is not in front of you: an approval or
/// a question, answered in the notification itself, an assistant's reply, replied to the same
/// way, and a board card that stopped on you (replied to the same way too: the reply goes on the
/// card and lets it go on), was handed to you to check, or is done, and a daily report written
/// since Shion connected. Clicking one lands on the very thing it was about (Landing.swift): the
/// reply in its chat, the approval or question selected in 等你确认, the card on its board, the
/// report; a click that started Shion lands there once it has connected. Screenshot and test runs
/// post nothing and ask for no permission; a test can have them written down instead
/// (`-ShionNotificationLog <file>`), answer or click them with a distributed notification
/// (`Notifier.testAnswer`, action `click` for a click), and start Shion as a click would
/// (`-ShionLaunchNotification <its userInfo as JSON>`).
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Opens the main window when it was closed (set by a view that has `openWindow`).
    var openMainWindow: (() -> Void)?
    private weak var store: AppStore?

    private enum Category {
        static let reply = "reply"
        static let approval = "approval"
        static let question = "question"
        /// A card that stopped on you.
        static let card = "card"
    }

    /// The approval actions are named as Hermes names the choices, so they answer directly.
    private enum Action {
        static let reply = "reply"
        static let once = "once"
        static let deny = "deny"
        static let answer = "answer"
        static let cardReply = "card-reply"
    }

    /// Typed into or picked in the notification; anything else is a click on it.
    private static let answers: Set<String> = [Action.reply, Action.once, Action.deny, Action.answer, Action.cardReply]

    /// A test run's file, where each notification is written down as a line of JSON.
    private static let testLog: String? = LaunchOptions.current.snapshot
        ? UserDefaults.standard.string(forKey: "ShionNotificationLog")
        : nil
    /// A test run's answer to one of its notifications: a distributed notification whose object
    /// is JSON with the notification's id, the action and the text typed (a test cannot type into
    /// a real notification, and its runner may not write files the app can see).
    static let testAnswer = Notification.Name("dev.shion.test.answer")
    /// A test run started as a click on a notification would start Shion: what it carried, as
    /// JSON. Read from the arguments as given: the defaults would try it as a property list first.
    private static let testLaunch: String? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard LaunchOptions.current.snapshot, let flag = arguments.firstIndex(of: "-ShionLaunchNotification"),
              flag + 1 < arguments.count
        else { return nil }
        return arguments[flag + 1]
    }()
    /// What a test run's notifications carried, by id, for its answers.
    private var written: [String: [String: String]] = [:]
    private var testAnswers: (any NSObjectProtocol)?

    func start(_ store: AppStore) {
        guard self.store == nil else { return }
        self.store = store
        store.board.onMoment = { [weak self] moment in
            self?.card(moment)
        }
        guard !LaunchOptions.current.snapshot else {
            if Self.testLog != nil {
                testAnswers = DistributedNotificationCenter.default().addObserver(forName: Self.testAnswer, object: nil,
                                                                                   queue: .main) { [weak self] note in
                    guard let json = note.object as? String else { return }
                    MainActor.assumeIsolated {
                        self?.answerForTest(json)
                    }
                }
            }
            if let launch = Self.testLaunch {
                clickedAtLaunch(launch)
            }
            return
        }
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
            UNNotificationCategory(
                identifier: Category.card,
                actions: [UNTextInputNotificationAction(identifier: Action.cardReply, title: "回复", options: [],
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
        case .secret:
            // who wants a password or a key, and nothing else: no actions, nothing typed here (a
            // notification's text field is plain text); a click opens Shion, where its card is
            content.title = "\(name) \(ask.title)"
        default:
            content.title = name
            content.body = ask.title
        }
        content.userInfo = ["bot": ask.botId, "ask": ask.id]
        post(ask.id, content, thread: ask.botId)
    }

    /// An assistant's reply; a newer one from the same assistant takes its place. `row` is the row
    /// Hermes stored it as, `item` the chat's row it streamed into: a click finds it by them.
    func reply(_ text: String, from name: String, botId: String, row: Int? = nil, item: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = name
        content.body = text.count > 300 ? String(text.prefix(300)) + "…" : text
        content.categoryIdentifier = Category.reply
        content.userInfo = Landing.replyInfo(botId: botId, text: text, row: row, item: item, at: Date())
        post("reply-\(botId)", content, thread: botId)
    }

    /// A daily report written since Shion connected (AppStore+Notices.swift); a newer one of the
    /// same kind takes its place.
    func report(_ report: Report, from name: String) {
        let content = UNMutableNotificationContent()
        content.title = "\(name) 写好了\(report.kind.label)日报"
        content.body = report.headline.isEmpty ? report.blocks.first?.items.first ?? "" : report.headline
        content.userInfo = Landing.reportInfo(report)
        post("report-\(report.kind.rawValue)", content, thread: "reports")
    }

    /// A board card that stopped on you, was handed to you to check, or is done, unless its page
    /// is in front of you (AppStore.shouldNotify). A newer one about the same card takes its place.
    func card(_ moment: CardMoment) {
        guard let store, store.shouldNotify(moment) else { return }
        let name = moment.assignee.flatMap { store.bot($0)?.name } ?? moment.assignee ?? "助手"
        let content = UNMutableNotificationContent()
        switch moment.kind {
        case .ask: content.title = "\(name) 卡住了，等你"
        case .review: content.title = "\(name) 做完了，等你检查"
        case .done: content.title = "\(name) 做完了"
        }
        let text = moment.text.map { $0.count > 300 ? String($0.prefix(300)) + "…" : $0 }
        content.body = [moment.title, text].compactMap { $0 }.joined(separator: "\n")
        if moment.kind == .ask {
            // what it needs can be typed right in: the reply goes on the card and lets it go on
            content.categoryIdentifier = Category.card
        }
        content.userInfo = ["card": moment.cardId, "board": moment.board ?? "", "bot": moment.assignee ?? ""]
        post(Self.cardNotice(moment.cardId, board: moment.board), content, thread: moment.assignee ?? "board")
    }

    /// A reply from a card's notification that did not go through: why, in its place. A click
    /// opens the card.
    private func cardReplyFailed(_ card: CardRef, _ why: String) {
        let content = UNMutableNotificationContent()
        content.title = "没能回复"
        content.body = why
        content.userInfo = ["card": card.id, "board": card.board ?? ""]
        post(Self.cardNotice(card.id, board: card.board), content, thread: "board")
    }

    func withdrawCard(_ id: String, board: String?) {
        withdraw(Self.cardNotice(id, board: board))
    }

    private static func cardNotice(_ id: String, board: String?) -> String {
        "card-\(board ?? "")-\(id)"
    }

    func withdraw(_ id: String) {
        guard store != nil, !LaunchOptions.current.snapshot else { return }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    func withdrawAll() {
        guard store != nil, !LaunchOptions.current.snapshot else { return }
        let center = UNUserNotificationCenter.current()
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()
    }

    private func post(_ id: String, _ content: UNMutableNotificationContent, thread: String) {
        guard store != nil else { return }
        guard !LaunchOptions.current.snapshot else { return writeDown(id, content) }
        content.sound = .default
        content.threadIdentifier = thread
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { _ in }
    }

    /// A test run's notification, as a line of JSON in its file: id, title, body, what can be
    /// answered in it (its category), and where a click would go.
    private func writeDown(_ id: String, _ content: UNMutableNotificationContent) {
        guard Self.testLog != nil else { return }
        let strings = Self.strings(content.userInfo)
        written[id] = strings
        append([
            "id": .string(id), "title": .string(content.title), "body": .string(content.body),
            "category": .string(content.categoryIdentifier), "info": .object(strings.mapValues { .string($0) }),
        ])
    }

    /// A line of JSON at the end of a test run's notification log.
    private func append(_ line: [String: JSONValue]) {
        guard let path = Self.testLog, let text = try? JSONValue.object(line).serialized() else { return }
        let data = Data((text + "\n").utf8)
        guard let handle = FileHandle(forWritingAtPath: path) else {
            _ = FileManager.default.createFile(atPath: path, contents: data)
            return
        }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        try? handle.close()
    }

    /// A notification's userInfo: every value here is a string.
    private nonisolated static func strings(_ info: [AnyHashable: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in info {
            if let key = key as? String, let value = value as? String {
                out[key] = value
            }
        }
        return out
    }

    /// A test run's answer to one of its notifications: it goes where the same answer from the
    /// notification goes, and the log notes that it was taken.
    func answerForTest(_ json: String) {
        guard let row = try? JSONValue.parse(json), let id = row["id"]?.string, let action = row["action"]?.string,
              let info = written[id]
        else { return }
        append(["answered": .string(id), "action": .string(action)])
        respond(action: action, info: info, text: row["text"]?.string ?? "")
    }

    // MARK: answers from the notification

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.actionIdentifier
        let info = Self.strings(response.notification.request.content.userInfo)
        let text = (response as? UNTextInputNotificationResponse)?.userText ?? ""
        Task { @MainActor in
            self.respond(action: action, info: info, text: text)
        }
        completionHandler()
    }

    private func respond(action: String, info: [String: String], text: String) {
        guard Self.answers.contains(action) else {
            // clicked, not answered: where it belongs, and on it the thing it was about
            return land(info)
        }
        let board = info["board"] ?? ""
        let card = info["card"].map { CardRef(board: board.isEmpty ? nil : board, id: $0) }
        handle(action: action, botId: info["bot"] ?? "", askId: info["ask"], card: card, text: text)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // posted only when its page is not in front, so it shows even while Shion is active
        completionHandler([.banner, .list, .sound])
    }

    private func handle(action: String, botId: String, askId: String?, card: CardRef?, text: String) {
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
        case Action.cardReply:
            guard let card else { return }
            Task {
                if let why = await store.replyToCard(card.id, board: card.board, text: text) {
                    self.cardReplyFailed(card, why)
                }
            }
        default:
            break
        }
    }

    /// A click: its page in front, with the thing it was about on it (Landing.swift).
    private func land(_ info: [String: String]) {
        guard let store else { return }
        if let landing = Landing(info: info) {
            Landings.shared.open(landing, in: store)
        }
        MainWindow.show()
    }

    /// A test run started as a click would start Shion: the click comes once the app is up, its
    /// main window there, as the system's does. Written down when taken, for the test to wait on.
    private func clickedAtLaunch(_ json: String) {
        guard let parsed = try? JSONValue.parse(json), case .object(let fields) = parsed else {
            append(["launched": .null, "error": .string("not JSON")])
            return
        }
        let info = fields.compactMapValues { $0.string }
        Task {
            var waited = 0
            while !NSApp.windows.contains(where: DockMode.isMain) && waited < 100 {
                try? await Task.sleep(for: .milliseconds(100))
                waited += 1
            }
            try? await Task.sleep(for: .milliseconds(300))
            self.land(info)
            self.append(["launched": .object(info.mapValues { .string($0) }),
                         "route": .string(self.store?.route.map { "\($0)" } ?? "")])
        }
    }
}
