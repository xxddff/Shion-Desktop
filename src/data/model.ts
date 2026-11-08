import type { Frame, ServerRequestMethod } from '../protocol/gateway';
import type { KanbanBoard, KanbanTask } from '../protocol/kanban';

export type BotStatus = 'working' | 'online' | 'idle' | 'cooldown' | 'offline';

export type PlatformKind = 'telegram' | 'discord' | 'slack' | 'cli' | 'api' | 'mobile' | 'kanban';

export interface PlatformLink {
  kind: PlatformKind;
  /** e.g. `@shion_atlas_bot`, `#eng-agents` */
  handle: string;
  connected: boolean;
}

/** A "bot" in Shion is one Hermes profile plus the gateway platforms it serves. */
export interface Bot {
  id: string;
  displayName: string;
  role: string;
  /** Index into the categorical identity palette (fixed order, never cycled). */
  hue: number;
  model: string;
  provider: string;
  platforms: PlatformLink[];
  status: BotStatus;
  statusNote?: string;
  sessionIds: string[];
  liveSessionId?: string;
  tokensToday: number;
  costToday: number;
  startedAt: number;
  lastActiveAt: number;
}

export type SessionSource = 'telegram' | 'discord' | 'slack' | 'tui' | 'kanban' | 'api';

export interface ToolCall {
  name: string;
  args: string;
  status: 'awaiting' | 'running' | 'done' | 'error';
  durationMs?: number;
  output?: string;
}

export interface TranscriptItem {
  id: string;
  role: 'user' | 'assistant' | 'tool' | 'system';
  at: number;
  text?: string;
  streaming?: boolean;
  tool?: ToolCall;
  /** Who typed it, for multi-user platforms. */
  author?: string;
}

export interface Session {
  id: string;
  botId: string;
  title: string;
  source: SessionSource;
  startedAt: number;
  live: boolean;
  tokens: number;
  taskId?: string;
  items: TranscriptItem[];
}

export interface InboxRequest {
  /** JSON-RPC id the reply must echo. */
  rpcId: string;
  method: Extract<ServerRequestMethod, 'approval' | 'clarify' | 'secret'>;
  botId: string;
  sessionId: string;
  at: number;
  approval?: { command: string; description: string };
  clarify?: { question: string; options: string[] };
  secret?: { name: string; prompt: string };
}

export type ActivityTone = 'neutral' | 'good' | 'warning' | 'critical' | 'info';

export interface Activity {
  id: number;
  at: number;
  tone: ActivityTone;
  botId?: string;
  taskId?: string;
  text: string;
}

export interface Toast {
  id: number;
  tone: ActivityTone;
  title: string;
  body?: string;
  href?: string;
}

export interface Connection {
  url: string;
  subprotocol: string;
  profileId: string;
  instanceId: string;
  state: 'connected' | 'reconnecting' | 'offline';
  latencyMs: number;
  capabilities: string[];
  kanbanUrl: string;
  lastEventId: number;
}

export interface AppState {
  connection: Connection;
  bots: Bot[];
  sessions: Record<string, Session>;
  boards: KanbanBoard[];
  tasks: KanbanTask[];
  inbox: InboxRequest[];
  activity: Activity[];
  frames: Frame[];
  toasts: Toast[];
  simulate: boolean;
}
