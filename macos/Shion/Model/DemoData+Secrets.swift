import Foundation

extension DemoData {
    /// Whose chat the screenshots' requests are in (`-ShionSecretsDemo YES`).
    var secretChatBot: String { "study" }

    /// 10:49 plus some seconds, for the requests' countdowns.
    private func second(_ minute: Int, _ seconds: Double) -> Date {
        at(0, 10, minute).addingTimeInterval(seconds)
    }

    /// 课程 turning the 7th lecture's recording into text: it installs ffmpeg with sudo, a request
    /// that went unanswered and is asked again, and the notion skill wants its key. At the demo's
    /// 10:52 the first has expired and the other two wait (parallel tool calls ask at once).
    var secretChat: [ChatItem] {
        [
            ChatItem(id: "k5", role: .user, at: second(49, 5), text: "第7回的录音转成文字，存进 Notion"),
            ChatItem(id: "k6", role: .tool, at: second(49, 10), text: "terminal · sudo apt-get install -y ffmpeg"),
            ChatItem(id: "k7", role: .tool, at: second(51, 20), text: "terminal · sudo apt-get install -y ffmpeg"),
            ChatItem(id: "k8", role: .tool, at: second(51, 30), text: "skill_view · notion"),
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
