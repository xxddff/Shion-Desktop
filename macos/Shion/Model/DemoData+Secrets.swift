import Foundation

#if DEBUG

extension DemoData {
    /// Whose chat the screenshots' requests are in (`-ShionSecretsDemo YES`).
    var secretChatBot: String { "study" }

    /// 10:49 plus some seconds, for the requests' countdowns.
    private func second(_ minute: Int, _ seconds: Double) -> Date {
        at(0, 10, minute).addingTimeInterval(seconds)
    }

    /// 课程 turning the 7th lecture's recording into text: it asks to clean up and where the notes
    /// go (both answered), installs ffmpeg with sudo, a request that went unanswered and is asked
    /// again, and the notion skill wants its key. At the demo's 10:52 the first password has
    /// expired and the other two wait (parallel tool calls ask at once).
    var secretChat: [ChatItem] {
        [
            ChatItem(id: "k5", role: .user, at: second(49, 5), text: "第7回的录音转成文字，存进 Notion"),
            ChatItem(id: "k6", role: .tool, at: second(49, 10), text: "terminal · sudo apt-get install -y ffmpeg"),
            ChatItem(id: "k7", role: .tool, at: second(51, 20), text: "terminal · sudo apt-get install -y ffmpeg"),
            ChatItem(id: "k8", role: .tool, at: second(51, 30), text: "skill_view · notion"),
        ]
    }

    /// What was answered in the story: in 课程's chat, a clean-up allowed once and where the notes
    /// go; to 詩音, in the ⌥Space window's exchange, whether to remind you tomorrow.
    func answeredAsks(server: String) -> [AnsweredAsk] {
        [
            AnsweredAsk(id: "demo-approval", kind: .approval, botId: secretChatBot, server: server,
                        at: second(49, 6), title: "要删掉上次转写剩下的临时文件吗？", outcome: "已允许这一次"),
            AnsweredAsk(id: "demo-question", kind: .clarify, botId: secretChatBot, server: server,
                        at: second(49, 8), title: "转写存进 Notion 的哪一页？", outcome: "你回答：数据结构与算法 第7回"),
            AnsweredAsk(id: "demo-reminder", kind: .clarify, botId: "shion", server: server,
                        at: at(0, 10, 52), title: "明天 9:30 提醒你出门吗？", outcome: "你回答：好"),
        ]
    }

    var secretRequests: [SecretRequest] {
        func sudo(_ id: String, asked: Date) -> SecretRequest {
            var request = SecretRequest(id: id, kind: .password, botId: secretChatBot, sessionId: "demo",
                                        at: asked, deadline: asked.addingTimeInterval(120))
            request.command = "sudo apt-get install -y ffmpeg"
            request.tool = "terminal"
            request.demo = true
            return request
        }
        var expired = sudo("demo-sudo-1", asked: second(49, 15))
        expired.state = .expired
        let again = sudo("demo-sudo-2", asked: second(51, 25))
        let asked = second(51, 35)
        var key = SecretRequest(id: "demo-key", kind: .key, botId: secretChatBot, sessionId: "demo",
                                at: asked, deadline: asked.addingTimeInterval(120))
        key.envVar = "NOTION_API_KEY"
        key.prompt = "Notion 的 internal integration token"
        key.skill = "notion"
        key.help = "https://www.notion.so/profile/integrations"
        key.demo = true
        return [expired, again, key]
    }
}
#endif
