/**
 * Hermes Kanban plugin — dashboard REST + WebSocket.
 *
 * REST:   /api/plugins/kanban/board, /tasks/:id, /tasks, /tasks/:id/comments,
 *         /profiles, /workers/active, /runs/{id}, /links, /dispatch …
 * Live:   WS /api/plugins/kanban/events?since=<event_id>&token=<session token>
 *
 * `task_events` is append-only with a monotonic id, so the client keeps the
 * last id it saw and resumes with `?since=` after a reconnect.
 *
 * Note: the plugin routes are unauthenticated at the HTTP layer; never point
 * Shion at a dashboard bound to 0.0.0.0 without a proxy in front.
 */

export const TASK_STATUSES = [
  'triage',
  'todo',
  'ready',
  'running',
  'blocked',
  'review',
  'done',
  'archived',
] as const;

export type TaskStatus = (typeof TASK_STATUSES)[number];

/** Columns the board shows; `archived` stays hidden. */
export const BOARD_COLUMNS: TaskStatus[] = ['triage', 'todo', 'ready', 'running', 'blocked', 'review', 'done'];

export type TaskEventKind =
  // lifecycle
  | 'created'
  | 'promoted'
  | 'claimed'
  | 'completed'
  | 'blocked'
  | 'dependency_wait'
  | 'block_loop_detected'
  | 'unblocked'
  | 'archived'
  // edits
  | 'assigned'
  | 'edited'
  | 'reprioritized'
  | 'status'
  // telemetry
  | 'spawned'
  | 'worker_registered'
  | 'heartbeat'
  | 'reclaimed'
  | 'crashed'
  | 'timed_out'
  | 'stale'
  | 'respawn_guarded'
  | 'spawn_failed'
  | 'protocol_violation'
  | 'gave_up'
  // comments ride along on the same stream in Shion's model
  | 'commented';

export type BlockKind = 'needs_input' | 'capability' | 'transient' | null;

export interface TaskEvent {
  id: number;
  taskId: string;
  kind: TaskEventKind;
  at: number;
  runId?: string | null;
  payload: Record<string, unknown>;
}

export interface TaskComment {
  id: string;
  /** Profile name, or `you` for the human operator. */
  author: string;
  body: string;
  at: number;
}

export type RunOutcome = 'running' | 'completed' | 'blocked' | 'crashed' | 'timed_out' | 'reclaimed';

export interface TaskRun {
  id: string;
  profile: string;
  outcome: RunOutcome;
  startedAt: number;
  endedAt?: number;
  summary?: string;
  error?: string;
}

export interface KanbanTask {
  id: string;
  board: string;
  title: string;
  body: string;
  /** Profile name; the dispatcher spawns `hermes -p <assignee>`. */
  assignee: string | null;
  status: TaskStatus;
  /** 0 low · 1 normal · 2 high · 3 urgent */
  priority: 0 | 1 | 2 | 3;
  tenant?: string;
  parents: string[];
  /** `scratch`, `dir:<abs path>`, or `worktree[:<path>]` */
  workspace: string;
  skills: string[];
  createdBy: string;
  createdAt: number;
  updatedAt: number;
  lastHeartbeatAt?: number;
  heartbeatNote?: string;
  block?: { reason: string; kind: BlockKind };
  comments: TaskComment[];
  events: TaskEvent[];
  runs: TaskRun[];
}

export interface KanbanBoard {
  slug: string;
  name: string;
}
