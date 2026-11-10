import Foundation

/// Catching up after a reconnect, as the official client does (apps/shared/src/json-rpc-gateway.ts
/// fetchReplay): each session's cursor (the newest frame's `seq` and `replay_epoch`) is kept
/// across sockets; on the new one, `session.events.since` from it gives every frame published while
/// Shion was away, which go through the same path as live ones. Asked before the session is
/// attached again, it also tells Hermes how far it answered: the `session.resume` that follows
/// first writes whatever was published in between (gateway/session_controls.py events_since and
/// resume, SessionEvents.catch_up), so nothing falls between the two.
extension Gateway {
    /// Every event frame, live or replayed: one seen already goes no further (EventCursors.swift);
    /// the others go to `onFrame` and `onEvent`.
    func deliver(_ params: JSONValue) {
        guard cursors.admit(params) else { return }
        onFrame?(params)
        onEvent?(params["type"]?.string ?? "", params["session_id"]?.string, params["payload"] ?? .null)
    }

    /// What the session published since its cursor, delivered before it is attached again. False
    /// when that cannot be had: no cursor, a server that no longer keeps the frames from there
    /// (`snapshot_required`: it restarted, or more came than it keeps), or no answer; the session's
    /// newest page then stands in for them.
    func replay(_ sessionId: String, profile: String) async -> Bool {
        guard let cursor = cursors[sessionId] else { return false }
        let reply: JSONValue
        do {
            reply = try await call("session.events.since", [
                "profile": .string(profile), "session_id": .string(sessionId),
                "last_sequence": .number(Double(cursor.seq)), "replay_epoch": .string(cursor.epoch),
            ])
        } catch {
            return false
        }
        guard reply["snapshot_required"]?.bool != true else {
            cursors.forget(sessionId)
            return false
        }
        for frame in reply["events"]?.array ?? [] {
            deliver(frame)
        }
        return true
    }
}
