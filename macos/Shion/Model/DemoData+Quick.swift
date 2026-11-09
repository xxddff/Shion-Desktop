import Foundation

extension DemoData {
    /// The ⌥Space window's screenshot: a sentence to 詩音 and her answer, after two tool calls
    /// (they fold into one line, as in the chat). Tomorrow's first class is 线性代数 at 10:40, and
    /// the ride takes 47 minutes, as in the demo calendar.
    var quickExchange: [ChatItem] {
        [
            ChatItem(id: "q1", role: .user, at: at(0, 10, 52), text: "明天几点出门？"),
            ChatItem(id: "q2", role: .tool, at: at(0, 10, 52), text: "calendar_events · 明天的日程"),
            ChatItem(id: "q3", role: .tool, at: at(0, 10, 52), text: "transit_route · 吉祥寺 → 新宿"),
            ChatItem(id: "q4", role: .assistant, at: at(0, 10, 52), text: """
                明天第一节是 **10:40 的线性代数**（3号馆 105）。

                9:40 出门就来得及：路上 47 分钟，中央線快速现在正常。要我 9:30 提醒你吗？
                """),
        ]
    }
}
