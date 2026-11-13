import Foundation

// The frames and rows captured from Hermes itself with a stand-in model (probe.py), read by the
// app's own Notices.read: a start frame as AppStore.noteTurnStart reads it, a user row as
// AppStore.transcriptItems does.
let capture = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]

func show(_ notices: [Notices.Notice]) {
    if notices.isEmpty { print("    -> no notice: shown as a message of yours, as typed") }
    for notice in notices {
        print("    -> event \(notice.event)")
        print("       shown text: \(notice.text.replacingOccurrences(of: "\n", with: " ⏎ ").prefix(330))")
    }
}

func frames(_ name: String, _ list: [[String: Any]]) {
    print("== \(name): turn starts")
    for frame in list where (frame["type"] as? String) == "message.start" {
        let payload = frame["payload"] as? [String: Any] ?? [:]
        print("  message.start seq \(frame["seq"] ?? "?") payload keys \(payload.keys.sorted())")
        if let text = payload["text"] as? String, !text.isEmpty {
            show(Notices.read(text, kind: payload["display_kind"] as? String, display: payload["display_text"] as? String))
        } else {
            print("    -> says nothing: no card from this frame")
        }
    }
}

func rows(_ name: String, _ page: Any?) {
    print("== \(name): rows")
    for row in ((page as? [String: Any])?["rows"] as? [[String: Any]]) ?? [] where (row["role"] as? String) == "user" {
        let text = (row["text"] as? String) ?? ""
        print("  row \(row["row_id"] ?? "nil") kind \(row["display_kind"] ?? "nil"): \(text.prefix(70).replacingOccurrences(of: "\n", with: " ⏎ "))…")
        show(Notices.read(text, kind: row["display_kind"] as? String,
                          display: (row["display_metadata"] as? [String: Any])?["display_text"] as? String))
    }
}

if let watching = capture["watching"] as? [String: Any] {
    frames("课程's Bot Chat, watched", watching["study_frames"] as? [[String: Any]] ?? [])
    rows("课程's Bot Chat, watched", watching["study_page"])
    frames("詩音's Bot Chat, watched", watching["chief_frames"] as? [[String: Any]] ?? [])
    rows("詩音's Bot Chat, watched", watching["chief_page"])
}
if let away = capture["away"] as? [String: Any] {
    frames("课程's Bot Chat, replayed after being away", (away["study_replay"] as? [String: Any])?["events"] as? [[String: Any]] ?? [])
    rows("课程's Bot Chat, after being away", away["study_page"])
}
for name in ["notify only", "nobody answers", "two at once"] {
    guard let part = capture[name] as? [String: Any] else { continue }
    frames("\(name): 詩音's Bot Chat", part["chief_frames"] as? [[String: Any]] ?? [])
}
if capture["notify only"] != nil {
    rows("课程's Bot Chat", capture["study_page"])
    rows("詩音's Bot Chat", capture["chief_page"])
}
if let list = capture["frames"] as? [[String: Any]] {
    frames("Bot Chat", list)
    rows("Bot Chat", capture["page"])
}
