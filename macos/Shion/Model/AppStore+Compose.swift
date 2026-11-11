import Foundation

extension AppStore {
    func draftKey(_ botId: String) -> String { serverKey + "|" + botId }
    func quoted(_ text: String, to botId: String) -> String {
        guard let quote = replyQuotes[draftKey(botId)] else { return text }
        let body = quote.text.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
        return "回复消息（\(quote.id)）：\n\(body)\n\n\(text)"
    }
    func sendWithMode(_ params: [String: JSONValue], botId: String, mode: SendMode) async throws {
        guard let session = params["session_id"]?.string else { throw GatewayError.offline }
        if turnRunning(botId), mode != .queue {
            guard let generation = control.fences[session]?.generation else { throw ControlError.unknownRun }
            if mode == .interrupt {
                _ = try await gateway.call("session.interrupt", ["profile": .string(botId), "session_id": .string(session),
                    "execution_generation": .number(Double(generation))])
            } else {
                guard params["attachments"] == nil else {
                    throw ControlError.refused("引导不支持图片，请选择排队或打断后发送", detail: nil)
                }
                let receipt = try await gateway.call("session.steer", ["profile": .string(botId), "session_id": .string(session),
                    "execution_generation": .number(Double(generation)), "text": params["text"] ?? ""])
                if receipt["status"]?.string == "queued" { return }
                guard receipt["delivered"]?.bool == false else {
                    throw ControlError.refused("引导未被接受，请检查当前回复后重试", detail: nil)
                }
            }
        }
        _ = try await gateway.call("prompt.submit", .object(params))
    }
}
