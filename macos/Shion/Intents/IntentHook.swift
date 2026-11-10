import Foundation

/// Test runs call the App Intents' perform() themselves, as Shortcuts or Siri would once they
/// have the parameters. A request is a distributed notification (`IntentHook.request`, its object
/// JSON: `{"id": "1", "intent": "tell", "text": "…"}`; `todos`; `open-assistant` with `query`,
/// found the way Shortcuts finds it; `open-confirm`), since the test runner may not write files
/// the app can see; what each said, or why it did nothing, is a line of JSON in
/// `-ShionIntentResults <file>`. Only in screenshot and test runs.
enum IntentHook {
    static let request = Notification.Name("dev.shion.test.intent")
    private static var observer: (any NSObjectProtocol)?

    static func start() {
        guard LaunchOptions.current.snapshot,
              let results = UserDefaults.standard.string(forKey: "ShionIntentResults"), observer == nil
        else { return }
        observer = DistributedNotificationCenter.default().addObserver(forName: request, object: nil, queue: .main) { note in
            guard let json = note.object as? String else { return }
            MainActor.assumeIsolated {
                guard let request = try? JSONValue.parse(json) else { return }
                Task {
                    write(await run(request), to: results)
                }
            }
        }
    }

    private static func run(_ request: JSONValue) async -> JSONValue {
        let id = request["id"] ?? .null
        IntentOutcome.note("")
        do {
            switch request["intent"]?.string {
            case "tell":
                var intent = TellChiefIntent()
                intent.text = request["text"]?.string ?? ""
                _ = try await intent.perform()
            case "todos":
                _ = try await TodayTodosIntent().perform()
            case "open-assistant":
                guard let target = try await AssistantQuery().entities(matching: request["query"]?.string ?? "").first else {
                    return ["id": id, "ok": false, "error": "没有找到这个助手"]
                }
                var intent = OpenAssistantIntent()
                intent.assistant = target
                _ = try await intent.perform()
            case "open-confirm":
                _ = try await OpenConfirmIntent().perform()
            default:
                return ["id": id, "ok": false, "error": "unknown intent"]
            }
            return ["id": id, "ok": true, "said": .string(IntentOutcome.said), "value": IntentOutcome.value]
        } catch let error as ShortcutError {
            return ["id": id, "ok": false, "error": .string(String(localized: error.localizedStringResource))]
        } catch {
            return ["id": id, "ok": false, "error": .string(error.localizedDescription)]
        }
    }

    private static func write(_ row: JSONValue, to path: String) {
        guard let line = try? row.serialized() else { return }
        let data = Data((line + "\n").utf8)
        guard let handle = FileHandle(forWritingAtPath: path) else {
            _ = FileManager.default.createFile(atPath: path, contents: data)
            return
        }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        try? handle.close()
    }
}
