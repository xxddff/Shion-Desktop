import Foundation

extension DemoData {
    /// The screenshot of a connection being got back (`-ShionReconnectDemo YES`), in 詩音's chat: a
    /// message that did not go out (`reconnectUnsent`), then one sent as the connection went, whose
    /// receipt it took with it (`reconnectUnsure`); the two that wait come after (`reconnectWaiting`).
    var reconnectChat: [ChatItem] {
        [
            ChatItem(id: reconnectUnsent, role: .user, at: at(0, 10, 46), text: "把实验报告的截止日期记成待办"),
            ChatItem(id: reconnectUnsure, role: .user, at: at(0, 10, 49), text: "顺便查一下明天的天气"),
        ]
    }

    var reconnectUnsent: String { "r-unsent" }
    var reconnectUnsure: String { "r-unsure" }

    /// Said while not connected: one long enough ago to go out saying when it was written.
    var reconnectWaiting: [(text: String, at: Date)] {
        [("提醒我明天带伞", at(0, 10, 31)), ("明天几点出门？", at(0, 10, 50))]
    }
}
