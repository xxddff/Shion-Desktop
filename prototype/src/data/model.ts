/**
 * Shion's UI model. Every assistant is a Hermes profile (Bot Mode semantics);
 * todos, calendar, reports and app activity come from the `shion` Hermes plugin
 * (`plugin.shion.*` RPCs) in the real app. Here they are seeded with example data.
 */

export type Area = 'study' | 'work' | 'life';

/** Identity colour slot. `accent` is reserved for the chief secretary. */
export type Hue = 'accent' | 0 | 1 | 2 | 3 | 4;

export type BotStatus = 'working' | 'online' | 'idle' | 'blocked';

export interface Routine {
  id: string;
  /** Shown as `[bot:<id>] <name>` in `hermes cron list`. */
  name: string;
  schedule: string;
  cron: string;
  nextRunAt?: number;
  lastRun?: { at: number; ok: boolean; note?: string };
}

export interface Bot {
  id: string;
  name: string;
  title: string;
  description: string;
  hue: Hue;
  chief?: boolean;
  model: string;
  status: BotStatus;
  statusNote: string;
  tools: string[];
  routines: Routine[];
  lastActiveAt: number;
}

export interface ToolNote {
  /** Human sentence for what the tool did, e.g. "查了 中央線快速 的运行情况". */
  summary: string;
  /** Raw tool name, shown on hover only. */
  tool: string;
  status: 'running' | 'done' | 'error';
}

export interface ChatItem {
  id: string;
  role: 'user' | 'assistant' | 'tool' | 'system' | 'handoff';
  at: number;
  text?: string;
  streaming?: boolean;
  tool?: ToolNote;
  /** For `handoff`: which bot the secretary passed the work to. */
  to?: string;
  /** Inline card referencing todos created by this turn. */
  todoIds?: string[];
}

export interface Chat {
  botId: string;
  items: ChatItem[];
}

export interface TodoSource {
  kind: 'class' | 'mail' | 'chat' | 'routine' | 'manual';
  label: string;
}

export interface Todo {
  id: string;
  title: string;
  area: Area;
  source: TodoSource;
  /** When you plan to do it (执行日期). */
  doAt?: number;
  /** Hard deadline (截止日期). */
  dueAt?: number;
  done: boolean;
  doneAt?: number;
  /** How many times Shion has nudged you about it. */
  nudges: number;
  notes?: string;
  /** Proposed by an assistant and not yet confirmed by you. */
  proposed?: boolean;
}

/** Work handed to an assistant: backed by the Hermes kanban board. */
export interface Delegation {
  id: string;
  botId: string;
  title: string;
  state: 'running' | 'waiting' | 'done';
  note: string;
  updatedAt: number;
}

export interface CalEvent {
  id: string;
  title: string;
  kind: 'class' | 'event' | 'commute' | 'focus';
  area: Area;
  start: number;
  end: number;
  place?: string;
  note?: string;
}

export interface Commute {
  leaveAt: number;
  arriveAt: number;
  route: string[];
  status: 'normal' | 'delayed' | 'suspended';
  statusNote: string;
  alternative?: string;
}

export type ReportKind = 'study' | 'work' | 'life' | 'news';

export interface ReportBlock {
  heading: string;
  lines: string[];
}

export interface Report {
  id: string;
  kind: ReportKind;
  date: number;
  botId: string;
  headline: string;
  blocks: ReportBlock[];
}

export interface NewsItem {
  title: string;
  source: string;
  check: 'verified' | 'single' | 'disputed';
  checkNote: string;
}

export interface UsageSlice {
  label: string;
  area: Area | 'other';
  minutes: number;
}

export interface AppUsage {
  app: string;
  area: Area | 'other';
  minutes: number;
}

export interface Ask {
  id: string;
  kind: 'approval' | 'clarify';
  botId: string;
  at: number;
  title: string;
  detail?: string;
  /** For an approval: a preview of what will be sent or run. */
  preview?: { label: string; body: string };
  options: { label: string; value: string; primary?: boolean; danger?: boolean }[];
  todoId?: string;
}

export interface Toast {
  id: number;
  title: string;
  body?: string;
  botId?: string;
  href?: string;
}

export interface Connection {
  name: string;
  kind: 'ssh' | 'url';
  host: string;
  state: 'connected' | 'reconnecting' | 'offline';
  latencyMs: number;
  localMac: 'off' | 'on';
  activityLog: boolean;
}

export interface AppState {
  connection: Connection;
  bots: Bot[];
  chats: Record<string, Chat>;
  todos: Todo[];
  delegations: Delegation[];
  events: CalEvent[];
  commute: Commute;
  reports: Report[];
  news: NewsItem[];
  usage: UsageSlice[];
  apps: AppUsage[];
  asks: Ask[];
  toasts: Toast[];
  simulate: boolean;
}
