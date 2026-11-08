import { useSyncExternalStore } from 'react';
import type { ApprovalChoice, Frame } from '../protocol/gateway';
import type { KanbanTask, TaskEventKind, TaskStatus } from '../protocol/kanban';
import type { Activity, AppState, Bot, InboxRequest, Session, Toast, TranscriptItem } from './model';
import { nextEventId, nextItemId, seedState } from './seed';

/**
 * A tiny external store. The prototype keeps everything in memory; the real
 * app swaps the simulator for a gateway client + kanban client that call the
 * same reducers below when frames arrive.
 */

let state: AppState = seedState();
const listeners = new Set<() => void>();

export const getState = () => state;
export function setState(fn: (s: AppState) => AppState) {
  state = fn(state);
  listeners.forEach((l) => l());
}
function subscribe(l: () => void) {
  listeners.add(l);
  return () => listeners.delete(l);
}
export function useAppState() {
  return useSyncExternalStore(subscribe, getState, getState);
}

/** Answers the user gave to server→client requests, read by the simulator. */
export const resolvedRequests = new Map<string, Record<string, unknown>>();

let frameSeq = 0;
let activitySeq = 100;
let toastSeq = 0;

// ---------------------------------------------------------------- reducers

export function withFrame(s: AppState, f: Omit<Frame, 'id' | 'at'>): AppState {
  const frame: Frame = { ...f, id: ++frameSeq, at: Date.now() };
  const frames = s.frames.length > 400 ? [...s.frames.slice(-300), frame] : [...s.frames, frame];
  return { ...s, frames };
}

export function withActivity(s: AppState, a: Omit<Activity, 'id' | 'at'>): AppState {
  const item: Activity = { ...a, id: ++activitySeq, at: Date.now() };
  return { ...s, activity: [item, ...s.activity].slice(0, 120) };
}

export function withToast(s: AppState, t: Omit<Toast, 'id'>): AppState {
  return { ...s, toasts: [...s.toasts, { ...t, id: ++toastSeq }].slice(-4) };
}

export function withTask(s: AppState, id: string, fn: (t: KanbanTask) => KanbanTask): AppState {
  return { ...s, tasks: s.tasks.map((t) => (t.id === id ? fn(t) : t)) };
}

export function withBot(s: AppState, id: string, fn: (b: Bot) => Bot): AppState {
  return { ...s, bots: s.bots.map((b) => (b.id === id ? fn(b) : b)) };
}

export function withSession(s: AppState, id: string, fn: (x: Session) => Session): AppState {
  const cur = s.sessions[id];
  if (!cur) return s;
  return { ...s, sessions: { ...s.sessions, [id]: fn(cur) } };
}

export function withItem(s: AppState, sessionId: string, item: TranscriptItem): AppState {
  return withSession(s, sessionId, (x) => ({ ...x, items: [...x.items, item] }));
}

/** Append a task event and mirror it as an inbound `/events` frame. */
export function withTaskEvent(
  s: AppState,
  taskId: string,
  kind: TaskEventKind,
  payload: Record<string, unknown> = {},
  patch: Partial<KanbanTask> = {},
): AppState {
  const event = { id: nextEventId(), taskId, kind, at: Date.now(), payload, runId: null };
  let next = withTask(s, taskId, (t) => ({ ...t, ...patch, updatedAt: event.at, events: [...t.events, event] }));
  next = withFrame(next, {
    dir: 'in',
    channel: 'kanban',
    kind: 'event',
    method: `task_events.${kind}`,
    payload: { id: event.id, task_id: taskId, kind, payload },
  });
  return { ...next, connection: { ...next.connection, lastEventId: event.id } };
}

// ---------------------------------------------------------------- actions

const STATUS_LABEL: Record<TaskStatus, string> = {
  triage: '待分拣',
  todo: '待办',
  ready: '就绪',
  running: '运行中',
  blocked: '阻塞',
  review: '待审',
  done: '完成',
  archived: '归档',
};
export const statusLabel = (s: TaskStatus) => STATUS_LABEL[s];

export function moveTask(taskId: string, status: TaskStatus) {
  setState((s) => {
    const t = s.tasks.find((x) => x.id === taskId);
    if (!t || t.status === status) return s;
    let next = withFrame(s, {
      dir: 'out',
      channel: 'kanban',
      kind: 'request',
      method: `PATCH /tasks/${taskId}`,
      payload: { status },
    });
    const patch: Partial<KanbanTask> = { status };
    if (status !== 'blocked') patch.block = undefined;
    next = withTaskEvent(next, taskId, status === 'blocked' ? 'blocked' : t.status === 'blocked' ? 'unblocked' : 'status', { status }, patch);
    return withActivity(next, { tone: 'neutral', taskId, text: `你把 ${taskId} 移到「${STATUS_LABEL[status]}」` });
  });
}

export function assignTask(taskId: string, assignee: string | null) {
  setState((s) => {
    let next = withFrame(s, { dir: 'out', channel: 'kanban', kind: 'request', method: `PATCH /tasks/${taskId}`, payload: { assignee } });
    next = withTaskEvent(next, taskId, 'assigned', { assignee }, { assignee });
    return withActivity(next, { tone: 'neutral', taskId, botId: assignee ?? undefined, text: `你把 ${taskId} 分配给 ${assignee ?? '（无人）'}` });
  });
}

export function addComment(taskId: string, body: string) {
  setState((s) => {
    const comment = { id: `c_${Date.now()}`, author: 'you', body, at: Date.now() };
    let next = withFrame(s, { dir: 'out', channel: 'kanban', kind: 'request', method: `POST /tasks/${taskId}/comments`, payload: { body } });
    next = withTask(next, taskId, (t) => ({ ...t, comments: [...t.comments, comment] }));
    return withTaskEvent(next, taskId, 'commented', { author: 'you' });
  });
}

let newTaskSeq = 0x900;
export function createTask(input: {
  title: string;
  body: string;
  assignee: string | null;
  priority: KanbanTask['priority'];
  board: string;
  status: TaskStatus;
}): string {
  const id = `t_${(++newTaskSeq).toString(16)}`;
  setState((s) => {
    const now = Date.now();
    const t: KanbanTask = {
      id,
      ...input,
      parents: [],
      workspace: 'scratch',
      skills: [],
      createdBy: 'you',
      createdAt: now,
      updatedAt: now,
      comments: [],
      events: [],
      runs: [],
    };
    let next = withFrame({ ...s, tasks: [...s.tasks, t] }, { dir: 'out', channel: 'kanban', kind: 'request', method: 'POST /tasks', payload: input });
    next = withTaskEvent(next, id, 'created', { assignee: input.assignee, status: input.status, parents: [] });
    return withActivity(next, { tone: 'neutral', taskId: id, text: `你创建了 ${id}「${input.title}」` });
  });
  return id;
}

export function answerRequest(req: InboxRequest, result: Record<string, unknown>) {
  resolvedRequests.set(req.rpcId, result);
  setState((s) => {
    let next: AppState = { ...s, inbox: s.inbox.filter((r) => r.rpcId !== req.rpcId) };
    next = withFrame(next, { dir: 'out', channel: 'gateway', kind: 'response', method: req.method, payload: { id: req.rpcId, result } });
    const bot = next.bots.find((b) => b.id === req.botId);
    const name = bot?.displayName ?? req.botId;

    if (req.method === 'approval') {
      const choice = result.choice as ApprovalChoice;
      const denied = choice === 'deny';
      // settle the tool call that was waiting on this approval
      next = withSession(next, req.sessionId, (x) => ({
        ...x,
        items: x.items.map((it) =>
          it.tool?.status === 'awaiting'
            ? {
                ...it,
                tool: {
                  ...it.tool,
                  status: denied ? 'error' : 'done',
                  durationMs: denied ? 0 : 2300,
                  output: denied ? '用户拒绝（deny）' : '+ 9c1e2f4...b77d0a1 feat/gateway-client (forced update)',
                },
              }
            : it,
        ),
      }));
      next = withBot(next, req.botId, (b) => ({ ...b, statusNote: 't_7a10 · 实现 gateway 客户端' }));
      const label = { once: '批准一次', session: '本会话内允许', always: '总是允许', deny: '拒绝' }[choice];
      return withActivity(next, { tone: denied ? 'warning' : 'good', botId: req.botId, text: `你${label}了 ${name} 的命令` });
    }

    if (req.method === 'clarify') {
      const answer = typeof result.answer === 'string' ? result.answer : undefined;
      next = answer
        ? withItem(next, req.sessionId, { id: nextItemId(), role: 'user', author: 'you', at: Date.now(), text: answer })
        : withItem(next, req.sessionId, { id: nextItemId(), role: 'system', at: Date.now(), text: '你跳过了这个问题' });
      next = withBot(next, req.botId, (b) => ({ ...b, statusNote: '正在拆解「Approvals 收件箱」' }));
      return withActivity(next, { tone: 'good', botId: req.botId, text: answer ? `你回答了 ${name}：${answer}` : `你跳过了 ${name} 的提问` });
    }

    // secret
    next = withItem(next, req.sessionId, { id: nextItemId(), role: 'system', at: Date.now(), text: `已写入 ${req.secret?.name}（值不会显示在 Shion 里）` });
    next = withBot(next, req.botId, (b) => ({
      ...b,
      status: 'online',
      statusNote: 'Discord 已重新连接',
      platforms: b.platforms.map((p) => ({ ...p, connected: true })),
    }));
    if (next.tasks.some((t) => t.id === 't_19ab' && t.status === 'blocked')) {
      next = withTaskEvent(next, 't_19ab', 'unblocked', {}, { status: 'ready', block: undefined });
    }
    return withActivity(next, { tone: 'good', botId: req.botId, text: `你为 ${name} 提供了 ${req.secret?.name}` });
  });
}

export function steerSession(sessionId: string, text: string, mode: 'steer' | 'background') {
  setState((s) => {
    const method = mode === 'steer' ? 'session.steer' : 'prompt.background';
    let next = withFrame(s, { dir: 'out', channel: 'gateway', kind: 'request', method, payload: { session_id: sessionId, text } });
    next = withItem(next, sessionId, { id: nextItemId(), role: 'user', author: 'you', at: Date.now(), text: mode === 'steer' ? `〔引导〕${text}` : `〔后台〕${text}` });
    return next;
  });
}

export function interruptSession(sessionId: string) {
  setState((s) => {
    let next = withFrame(s, { dir: 'out', channel: 'gateway', kind: 'request', method: 'session.interrupt', payload: { session_id: sessionId } });
    next = withSession(next, sessionId, (x) => ({
      ...x,
      items: [
        ...x.items.map((it) => (it.streaming ? { ...it, streaming: false } : it)),
        { id: nextItemId(), role: 'system', at: Date.now(), text: '你打断了当前回合（turn_exit_reason: interrupted_by_user）' },
      ],
    }));
    const botId = next.sessions[sessionId]?.botId;
    return botId ? withActivity(next, { tone: 'warning', botId, text: `你打断了 ${botId} 的当前回合` }) : next;
  });
}

export function setSimulate(on: boolean) {
  setState((s) => ({ ...s, simulate: on }));
}

export function dismissToast(id: number) {
  setState((s) => ({ ...s, toasts: s.toasts.filter((t) => t.id !== id) }));
}

/** The frames a real client exchanges right after the socket opens. */
let handshakeDone = false;
export function seedHandshake() {
  if (handshakeDone) return;
  handshakeDone = true;
  setState((s) => {
    const c = s.connection;
    let n = withFrame(s, { dir: 'in', channel: 'gateway', kind: 'event', method: 'gateway.ready', payload: { instance_id: c.instanceId, profile_id: c.profileId } });
    n = withFrame(n, { dir: 'out', channel: 'gateway', kind: 'request', method: 'client.capabilities', payload: { server_requests: true } });
    n = withFrame(n, { dir: 'out', channel: 'gateway', kind: 'request', method: 'runtime.describe', payload: {} });
    n = withFrame(n, { dir: 'in', channel: 'gateway', kind: 'response', method: 'runtime.describe', payload: { capabilities: c.capabilities } });
    n = withFrame(n, { dir: 'out', channel: 'gateway', kind: 'request', method: 'session.active_list', payload: {} });
    for (const sess of Object.values(n.sessions).filter((x) => x.live)) {
      n = withFrame(n, { dir: 'out', channel: 'gateway', kind: 'request', method: 'session.activate', payload: { session_id: sess.id } });
    }
    n = withFrame(n, { dir: 'out', channel: 'kanban', kind: 'request', method: 'GET /board', payload: { board: 'default' } });
    n = withFrame(n, { dir: 'out', channel: 'kanban', kind: 'request', method: 'WS /events', payload: { since: c.lastEventId } });
    for (const r of n.inbox) {
      n = withFrame(n, { dir: 'in', channel: 'gateway', kind: 'request', method: r.method, payload: { id: r.rpcId, session_id: r.sessionId } });
    }
    return n;
  });
}
