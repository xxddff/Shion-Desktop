import Foundation

/// Test runs call the App Intents' perform() themselves, as Shortcuts or Siri would once they
/// have the parameters: a line of JSON each in `-ShionIntentRequests <file>`
/// (`{"id": "1", "intent": "tell", "text": "…"}`; `todos`; `open-assistant` with `query`, found
/// as Shortcuts finds it; `open-confirm`), what each said or why it did nothing in
/// `-ShionIntentResults <file>`. Only in screenshot and test runs.
enum IntentHook {
    static func start() {
        let defaults = UserDefaults.standard
        guard LaunchOptions.current.snapshot,
              let requests = defaults.string(forKey: "ShionIntentRequests"),
              let results = defaults.string(forKey: "ShionIntentResults")
        else { return }
        Task {
            var read = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard let text = try? String(contentsOfFile: requests, encoding: .utf8) else { continue }
                let lines = text.split(separator: "\n")
                guard lines.count > read else { continue }
                let fresh = lines[read...].map(String.init)
                read = lines.count
                for line in fresh {
                    guard let request = try? JSONValue.parse(line) else { continue }
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
                intent.target = target
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
