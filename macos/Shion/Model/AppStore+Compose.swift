import Foundation

/// A steer has no submission receipt to reconcile after a lost response. It may already have
/// reached the running agent, so it must never become a prompt that is offered for safe resend.
nonisolated enum SendReceiptError: Error {
    case steerUnconfirmed
}

extension AppStore {
    func draftKey(_ botId: String) -> String { serverKey + "|" + botId }
    func quoted(_ text: String, to botId: String) -> String {
        guard let quote = replyQuotes[draftKey(botId)] else { return text }
        let body = quote.text.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
        return "回复这条消息：\n\(body)\n\n\(text)"
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
                let receipt: JSONValue
                do {
                    receipt = try await gateway.call("session.steer", ["profile": .string(botId), "session_id": .string(session),
                        "execution_generation": .number(Double(generation)), "text": params["text"] ?? ""])
                } catch let error as GatewayError {
                    if case .rpc = error { throw error }
                    throw SendReceiptError.steerUnconfirmed
                } catch {
                    throw SendReceiptError.steerUnconfirmed
                }
                if receipt["status"]?.string == "queued" { return }
                guard receipt["delivered"]?.bool == false else {
                    // Hermes can report "rejected" after delivery. Only delivered:false allows
                    // admission as a new prompt; otherwise ask the user to check the reply.
                    throw SendReceiptError.steerUnconfirmed
                }
            }
        }
        _ = try await gateway.call("prompt.submit", .object(params))
    }

    /// Shared by text and attachment submissions. This follows the RPC actually attempted, not
    /// the selected mode: an idle/rejected steer can fall back to an idempotent prompt.submit.
    func noteSubmissionFailure(_ error: Error, id: String) {
        switch error {
        case SendReceiptError.steerUnconfirmed:
            deliveries.set(id, .unconfirmedSteer)
        case GatewayError.rpc(_, let message, let reason):
            deliveries.set(id, .unsent(DeliveryCheck.refusal(reason) ?? reason ?? message))
        case let error as ControlError:
            deliveries.set(id, .unsent(error.localizedDescription))
        default:
            deliveries.set(id, .unsure)
        }
    }
}
