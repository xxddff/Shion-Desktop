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
  /** `card`: the turn created or reported on a kanban card (shown as a live chip). */
  role: 'user' | 'assistant' | 'tool' | 'system' | 'card';
  at: number;
  text?: string;
  streaming?: boolean;
  tool?: ToolNote;
  cardId?: string;
  /** Inline card referencing todos created by this turn. */
  todoIds?: string[];
}

/**
 * A conversation. `bot` is the assistant's one Bot Chat (talk to it directly);
 * `worker` is the session the kanban dispatcher spawns to run one card.
 */
export interface Chat {
  key: string;
  botId: string;
  kind: 'bot' | 'worker';
  cardId?: string;
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

/**
 * A Hermes kanban card: work handed to an assistant. The dispatcher claims it,
 * spawns a worker session for the assignee, and the card records heartbeats,
 * blocks, comments (the inter-agent channel) and every run.
 */
export type CardStatus = 'todo' | 'ready' | 'running' | 'blocked' | 'review' | 'done';

export interface CardComment {
  /** A bot id, or `you`. */
  author: string;
  body: string;
  at: number;
}

export interface CardRun {
  id: string;
  startedAt: number;
  endedAt?: number;
  outcome: 'running' | 'completed' | 'blocked';
  note?: string;
}

export interface Card {
  id: string;
  title: string;
  body: string;
  assignee: string;
  /** A bot id, `you`, or the routine that created it. */
  createdBy: string;
  status: CardStatus;
  parents?: string[];
  block?: { kind: 'needs_input' | 'capability' | 'transient'; reason: string };
  heartbeat?: { at: number; note: string };
  summary?: string;
  comments: CardComment[];
  runs: CardRun[];
  createdAt: number;
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

/** What a window was, as the on-device model on this Mac judged it. */
export type ActivityKind = 'study' | 'work' | 'life' | 'fun' | 'social' | 'other';

/**
 * One window that was in front on this Mac. Kept on the Mac only: 詩音 hears
 * the verdict (on the plan or not, for how long, what kind), never the title.
 */
export interface FocusSample {
  at: number;
  app: string;
  title: string;
  kind: ActivityKind;
  /** Against the plan at the time: the planned thing, related to it, unrelated, no plan, or away from the Mac. */
  fit: 'same' | 'related' | 'unrelated' | 'none' | 'away';
}

/** The focus check: is what you are doing what you planned to be doing now? */
export interface Focus {
  enabled: boolean;
  pausedUntil?: number;
  /** What you planned to be doing now: a todo at its time, or a class or focus block. */
  target?: { todoId?: string; title: string; from: number };
  samples: FocusSample[];
  /** What this Mac last told 詩音, word for word. */
  sent?: { at: number; text: string; state: 'on' | 'off' };
}

/**
 * A bot's own cloud desktop (Hermes Bot Screen): an Xfce screen on the VPS
 * that the bot's computer_use and headed browser act on. You can watch it,
 * take over (the control lease) and hand back.
 */
export type ScreenApp = 'sso' | 'moodle' | 'news' | 'transit';

export interface Screen {
  botId: string;
  running: boolean;
  control: 'bot' | 'you';
  app?: ScreenApp;
  url?: string;
  /** What the bot is doing on the screen right now. */
  activity?: string;
  /** Why the bot stopped and needs a human, e.g. two-step sign-in. */
  needsHuman?: string;
  /** Set when you hand control back after a takeover. */
  handedBackAt?: number;
  /** Text you typed into fields on the screen while you held it (prototype only; the app sends keys or a paste). */
  typed?: Record<string, string>;
}

export interface Ask {
  id: string;
  kind: 'approval' | 'clarify' | 'takeover';
  botId: string;
  at: number;
  title: string;
  detail?: string;
  /** For an approval: a preview of what will be sent or run. */
  preview?: { label: string; body: string };
  options: { label: string; value: string; primary?: boolean; danger?: boolean }[];
  todoId?: string;
  /** The kanban card that is blocked on this ask, if any. */
  cardId?: string;
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
  /** How the remote `hermes serve` is reached. */
  kind: 'cloudflare' | 'tailscale' | 'ssh';
  host: string;
  /** What gets the client through, e.g. a Cloudflare Access service token. */
  auth: string;
  state: 'connected' | 'reconnecting' | 'offline';
  latencyMs: number;
  localMac: 'off' | 'on';
  activityLog: boolean;
}

/**
 * How the Hermes kanban dispatcher hands out work (the `kanban.*` keys in config.yaml).
 * Hermes defaults, as of main in 2026-11:
 * - maxInProgress unset: on Linux the gateway derives MemTotal / 512 MB, clamped to 2–8
 *   (macOS and Windows: no cap); the docs still say "unlimited".
 * - perProfile unset: no per-assistant limit.
 * - one dispatch tick every 60 s, or right away via POST /api/plugins/kanban/dispatch.
 * - under memory pressure a tick spawns at most one worker (elevated) or none (critical).
 */
export interface DispatchConfig {
  maxInProgress: number | null;
  perProfile: number | null;
  intervalSec: number;
}

export interface AppState {
  connection: Connection;
  bots: Bot[];
  chats: Record<string, Chat>;
  todos: Todo[];
  cards: Card[];
  events: CalEvent[];
  commute: Commute;
  reports: Report[];
  news: NewsItem[];
  usage: UsageSlice[];
  apps: AppUsage[];
  focus: Focus;
  asks: Ask[];
  screens: Record<string, Screen>;
  dispatch: DispatchConfig;
  toasts: Toast[];
  simulate: boolean;
}
