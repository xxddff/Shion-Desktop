/**
 * Hermes TUI Gateway JSON-RPC — the subset Shion relies on.
 *
 * Transport: WebSocket at `/api/ws` on a profile's shared gateway,
 * subprotocol `hermes-gateway-v1`, single-use ticket per connection
 * (`hermes gateway attach --json [--start|--recover]` hands out
 * `{url, protocols, profile_id, instance_id}`).
 *
 * Handshake order a host must follow:
 *   1. wait for `gateway.ready`
 *   2. call `client.capabilities` with `{ server_requests: true }`
 *      (skipping this makes the gateway refuse every approval/clarify request)
 *   3. read `runtime.describe` before `session.create`
 *
 * Source of truth: tui_gateway/server.py and the "Programmatic Integration"
 * page of the Hermes Agent docs. Field shapes below are the prototype's
 * best reading of those docs; confirm against the real catalog before wiring.
 */

export const GATEWAY_SUBPROTOCOL = 'hermes-gateway-v1';

/** Client → gateway methods Shion calls. */
export type GatewayMethod =
  | 'client.capabilities'
  | 'runtime.describe'
  | 'session.list'
  | 'session.active_list'
  | 'session.activate'
  | 'session.transcript'
  | 'session.events.since'
  | 'session.status'
  | 'session.usage'
  | 'session.interrupt'
  | 'session.steer'
  | 'prompt.submit'
  | 'prompt.background'
  | 'delegation.status'
  | 'ping';

/** Gateway → client notifications Shion renders. */
export type GatewayEventName =
  | 'gateway.ready'
  | 'message.delta'
  | 'message.complete'
  | 'tool.start'
  | 'tool.generating'
  | 'tool.complete'
  | 'request.cancel';

/**
 * Gateway → client *requests*. The host must answer with the same string id,
 * or with error -32601 for anything it does not implement.
 */
export type ServerRequestMethod =
  | 'approval'
  | 'clarify'
  | 'sudo'
  | 'secret'
  | 'vault.code'
  | 'vault.unlock_prompt'
  | 'connection'
  | 'terminal.read'
  | 'window.read'
  | 'preview.act'
  | 'tour';

export type ApprovalChoice = 'once' | 'session' | 'always' | 'deny';

/** One raw frame as shown in the protocol inspector. */
export interface Frame {
  id: number;
  at: number;
  /** `in` = gateway/kanban → Shion, `out` = Shion → gateway/kanban. */
  dir: 'in' | 'out';
  channel: 'gateway' | 'kanban';
  kind: 'event' | 'request' | 'response';
  method: string;
  payload: unknown;
}
