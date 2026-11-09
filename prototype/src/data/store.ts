import { useSyncExternalStore } from 'react';
import { demoNow } from './clock';
import { DEMO_WINDOWS, KIND_LABEL, focusNow } from './focus';
import { hm } from '../ui/format';
import type { AppState, Ask, Card, ChatItem, Screen, Todo, Toast } from './model';
import { nextId, seedState } from './seed';

/**
 * In-memory store. In the SwiftUI app this becomes an @Observable model fed by
 * the canonical gateway client and the `plugin.shion.*` RPCs.
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

/** Messages you sent that the simulator should answer. */
export const replyQueue: { botId: string; text: string }[] = [];

let toastSeq = 0;

// ------------------------------------------------------------- reducers

/** Append to a chat by key: a bot id for its Bot Chat, `w:<card id>` for a worker session. */
export const withItem = (s: AppState, key: string, item: Omit<ChatItem, 'id'>): AppState => {
  const chat = s.chats[key] ?? { key, botId: key, kind: 'bot' as const, items: [] };
  return { ...s, chats: { ...s.chats, [key]: { ...chat, items: [...chat.items, { ...item, id: nextId() }] } } };
};

export const withTodo = (s: AppState, id: string, fn: (t: Todo) => Todo): AppState => ({
  ...s,
  todos: s.todos.map((t) => (t.id === id ? fn(t) : t)),
});

export const withCard = (s: AppState, id: string, fn: (c: Card) => Card): AppState => ({
  ...s,
  cards: s.cards.map((c) => (c.id === id ? { ...fn(c), updatedAt: demoNow() } : c)),
});

/** Dispatcher claims a ready card: a new run and (on the first run) a worker session for the assignee. */
export function withClaim(s: AppState, id: string): AppState {
  const card = s.cards.find((c) => c.id === id);
  if (!card) return s;
  const n = card.runs.length + 1;
  let next = withCard(s, id, (c) => ({
    ...c,
    status: 'running',
    block: undefined,
    heartbeat: { at: demoNow(), note: '刚认领' },
    runs: [...c.runs, { id: `run-${id}-${n}`, startedAt: demoNow(), outcome: 'running' }],
  }));
  const key = `w:${id}`;
  if (!next.chats[key]) next = { ...next, chats: { ...next.chats, [key]: { key, botId: card.assignee, kind: 'worker', cardId: id, items: [] } } };
  const last = card.comments[card.comments.length - 1];
  return withItem(next, key, {
    role: 'system',
    text: `第 ${n} 次 · ${hm(demoNow())} 开始${n > 1 && last ? ` · 先读了留言：「${last.body}」` : ''}`,
    at: demoNow(),
  });
}

export function withComplete(s: AppState, id: string, summary: string): AppState {
  let next = withCard(s, id, (c) => ({
    ...c,
    status: 'done',
    summary,
    heartbeat: undefined,
    runs: c.runs.map((r) => (r.outcome === 'running' ? { ...r, outcome: 'completed', endedAt: demoNow() } : r)),
  }));
  // children whose parents are all done move from todo to ready
  for (const child of next.cards.filter((c) => c.status === 'todo' && c.parents?.includes(id))) {
    if (child.parents!.every((p) => next.cards.find((x) => x.id === p)?.status === 'done')) {
      next = withCard(next, child.id, (c) => ({ ...c, status: 'ready' }));
    }
  }
  return next;
}

export function withBlock(s: AppState, id: string, block: NonNullable<Card['block']>): AppState {
  return withCard(s, id, (c) => ({
    ...c,
    status: 'blocked',
    block,
    heartbeat: undefined,
    runs: c.runs.map((r) => (r.outcome === 'running' ? { ...r, outcome: 'blocked', endedAt: demoNow(), note: block.reason } : r)),
  }));
}

export const withBot = (s: AppState, id: string, patch: Partial<AppState['bots'][number]>): AppState => ({
  ...s,
  bots: s.bots.map((b) => (b.id === id ? { ...b, ...patch } : b)),
});

export const withScreen = (s: AppState, botId: string, patch: Partial<Screen>): AppState => ({
  ...s,
  screens: { ...s.screens, [botId]: { ...(s.screens[botId] ?? { botId, running: false, control: 'bot' }), ...patch } },
});

export const withToast = (s: AppState, t: Omit<Toast, 'id'>): AppState => ({
  ...s,
  // like macOS banners: at most two on screen, older ones are dropped rather than queued
  toasts: [...s.toasts, { ...t, id: ++toastSeq }].slice(-2),
});

/** Most urgent first: a bot stuck on your screen, then things it wants to send, then questions. */
const ASK_RANK = { takeover: 0, approval: 1, clarify: 2 } as const;
export const sortAsks = (asks: Ask[]) => [...asks].sort((a, b) => ASK_RANK[a.kind] - ASK_RANK[b.kind] || b.at - a.at);

// ------------------------------------------------------------- actions

export function toggleTodo(id: string) {
  setState((s) => withTodo(s, id, (t) => ({ ...t, done: !t.done, doneAt: t.done ? undefined : demoNow(), proposed: false })));
}

export function updateTodo(id: string, patch: Partial<Todo>) {
  setState((s) => withTodo(s, id, (t) => ({ ...t, ...patch })));
}

export function confirmTodo(id: string) {
  setState((s) => withTodo(s, id, (t) => ({ ...t, proposed: false })));
}

export function addTodo(input: Pick<Todo, 'title' | 'area'> & Partial<Todo>): string {
  const id = nextId('td');
  setState((s) => ({
    ...s,
    todos: [...s.todos, { id, done: false, nudges: 0, source: { kind: 'manual', label: '手动添加' }, ...input }],
  }));
  return id;
}

// ------------------------------------------------- cloud desktop (Bot Screen)

/** `display.lease.acquire`: your keyboard and mouse drive the bot's screen. */
export function takeOver(botId: string) {
  setState((s) => {
    let next = withScreen(s, botId, { control: 'you', running: true });
    next = {
      ...next,
      asks: next.asks.filter((a) => !(a.kind === 'takeover' && a.botId === botId)),
      toasts: next.toasts.filter((t) => t.href !== `#desktop-${botId}`),
    };
    return withItem(next, botId, { role: 'system', text: '你接管了云桌面', at: demoNow() });
  });
}

/** `display.lease.release`: the bot re-captures the screen and continues. */
export function handBack(botId: string) {
  setState((s) => {
    let next = withScreen(s, botId, { control: 'bot', handedBackAt: demoNow(), needsHuman: undefined });
    next = withItem(next, botId, { role: 'system', text: '你把云桌面交还给了助手', at: demoNow() });
    // a card blocked on "needs a human on the screen" goes back to ready with your note for the next run
    const blocked = next.cards.find((c) => c.assignee === botId && c.status === 'blocked' && c.block?.kind === 'needs_input');
    if (blocked) {
      next = withCard(next, blocked.id, (c) => ({
        ...c,
        status: 'ready',
        block: undefined,
        comments: [...c.comments, { author: 'you', body: '我在云桌面上登录好了，继续吧。', at: demoNow() }],
      }));
    }
    return next;
  });
}

/** `display.start`: screens are off until someone needs them. */
export function startScreen(botId: string) {
  setState((s) => withScreen(s, botId, { running: true, activity: '桌面已启动，空闲中' }));
}

/** What a field on the cloud desktop now holds after you typed or pasted into it. */
export function typeOnScreen(botId: string, field: string, value: string) {
  setState((s) => withScreen(s, botId, { typed: { ...s.screens[botId]?.typed, [field]: value } }));
}

export function answerAsk(ask: Ask, value: string) {
  if (ask.kind === 'takeover') {
    if (value === 'go') takeOver(ask.botId);
    else setState((s) => ({ ...s, asks: s.asks.filter((a) => a.id !== ask.id) }));
    return;
  }
  setState((s) => {
    let next: AppState = { ...s, asks: s.asks.filter((a) => a.id !== ask.id) };
    const label = ask.options.find((o) => o.value === value)?.label ?? value;
    next = withItem(next, ask.botId, { role: 'user', text: label, at: demoNow() });

    if (ask.id === 'ask-mail') {
      if (value === 'send') {
        next = withItem(next, 'mail', { role: 'tool', at: demoNow(), tool: { summary: '把回复发给了 中村老师', tool: 'mail.send', status: 'done' } });
        next = withItem(next, 'mail', { role: 'assistant', text: '已发送。「回复中村老师」这件待办我帮你勾掉了。', at: demoNow() });
        next = withTodo(next, 'td1', (t) => ({ ...t, done: true, doneAt: demoNow() }));
      } else if (value === 'edit') {
        next = withItem(next, 'mail', { role: 'assistant', text: '好，草稿放在邮箱的「草稿」里了，你改完直接发就行。', at: demoNow() });
      } else {
        next = withItem(next, 'mail', { role: 'assistant', text: '好，这封不发了。待办还留着，记得自己回一下。', at: demoNow() });
      }
      next = withBot(next, 'mail', { status: 'online', statusNote: '下次整理 13:00' });
    }

    if (ask.id === 'ask-hw4') {
      next = withTodo(next, 'td7', (t) => {
        if (value === 'later') return { ...t, proposed: false, doAt: (t.doAt ?? demoNow()) + 86_400_000 };
        if (value === 'self') return { ...t, proposed: false, doAt: undefined };
        return { ...t, proposed: false };
      });
      next = withItem(next, 'shion', {
        role: 'assistant',
        text: value === 'self' ? '好，作业4 不排执行时间，截止前一天我会再提醒你。' : '好，已经排进日程，到时间我会提醒你。',
        at: demoNow(),
      });
    }

    if (ask.id === 'ask-commute') {
      next = withItem(next, 'commute', {
        role: 'assistant',
        text: value === 'skip' ? '好，明天不提醒。' : value === 'earlier' ? '好，明天 09:40 提醒你出门。' : '好，明天 09:50 提醒你出门，出发前我会再查一次运行情况。',
        at: demoNow(),
      });
    }
    return next;
  });
}

export function sendMessage(botId: string, text: string) {
  setState((s) => withItem(s, botId, { role: 'user', text, at: demoNow() }));
  replyQueue.push({ botId, text });
}

export function runRoutine(botId: string, routineName: string) {
  setState((s) => {
    let next = withItem(s, botId, { role: 'system', text: `手动运行 · ${routineName}`, at: demoNow() });
    next = withBot(next, botId, { lastActiveAt: demoNow() });
    const bot = next.bots.find((b) => b.id === botId);
    return withToast(next, { title: `已让「${bot?.name}」现在运行「${routineName}」`, botId, href: `#chat-${botId}` });
  });
}

// ------------------------------------------------------------- kanban

/** `POST /tasks/:id/comments`: comments are how people and bots hand context to the next run. */
export function commentCard(id: string, body: string) {
  setState((s) => withCard(s, id, (c) => ({ ...c, comments: [...c.comments, { author: 'you', body, at: demoNow() }] })));
}

/** Unblock with a comment: the card returns to ready and the dispatcher re-runs it with the comment in context. */
export function unblockCard(id: string, body: string) {
  setState((s) => {
    let next = withCard(s, id, (c) => ({ ...c, status: 'ready', block: undefined, comments: [...c.comments, { author: 'you', body, at: demoNow() }] }));
    next = { ...next, asks: next.asks.filter((a) => a.cardId !== id) };
    return next;
  });
}

export function setSimulate(on: boolean) {
  setState((s) => ({ ...s, simulate: on }));
}

export function setActivityLog(on: boolean) {
  setState((s) => ({ ...s, connection: { ...s.connection, activityLog: on } }));
}

/**
 * This Mac tells 詩音 the verdict through the shion plugin, which puts it in
 * her Bot Chat (Hermes `inject_message`): words only, never window titles.
 * Shion does not show that injected line; Settings says what is sent.
 */
export function withFocusReport(s: AppState, state: 'on' | 'off'): AppState {
  const f = s.focus;
  if (!f.target) return s;
  const v = focusNow(s, demoNow());
  const text =
    state === 'off' && v.state === 'off'
      ? `「${f.target.title}」原定 ${hm(f.target.from)}，已经 ${v.minutes} 分钟没在做；在做的是${KIND_LABEL[v.kind]}。`
      : `回到「${f.target.title}」上了。`;
  return { ...s, focus: { ...f, sent: { at: demoNow(), text, state } } };
}

/** Prototype only: pretend a window came to the front; the on-device model judges it against the plan. */
export function frontWindow(index: number) {
  const w = DEMO_WINDOWS[index];
  if (!w) return;
  setState((s) => {
    const planned = !!s.focus.target && demoNow() >= s.focus.target.from;
    const sample = { ...w, fit: planned || w.fit === 'away' ? w.fit : ('none' as const), at: demoNow() };
    let next: AppState = { ...s, focus: { ...s.focus, samples: [...s.focus.samples, sample].slice(-20) } };
    // once 詩音 has heard you were off the plan, tell her as soon as you are back on it
    if (focusNow(next, demoNow()).state === 'on' && next.focus.sent?.state === 'off') next = withFocusReport(next, 'on');
    return next;
  });
}

export function pauseFocus(minutes: number) {
  setState((s) => ({ ...s, focus: { ...s.focus, pausedUntil: demoNow() + minutes * 60_000 } }));
}

export function resumeFocus() {
  setState((s) => ({ ...s, focus: { ...s.focus, pausedUntil: undefined } }));
}

export function setFocusEnabled(on: boolean) {
  setState((s) => ({ ...s, focus: { ...s.focus, enabled: on, pausedUntil: undefined } }));
}

export function dismissToast(id: number) {
  setState((s) => ({ ...s, toasts: s.toasts.filter((t) => t.id !== id) }));
}
