import { useSyncExternalStore } from 'react';
import { demoNow } from './clock';
import type { AppState, Ask, ChatItem, Delegation, Screen, Todo, Toast } from './model';
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

export const withItem = (s: AppState, botId: string, item: Omit<ChatItem, 'id'>): AppState => {
  const chat = s.chats[botId] ?? { botId, items: [] };
  return { ...s, chats: { ...s.chats, [botId]: { ...chat, items: [...chat.items, { ...item, id: nextId() }] } } };
};

export const withTodo = (s: AppState, id: string, fn: (t: Todo) => Todo): AppState => ({
  ...s,
  todos: s.todos.map((t) => (t.id === id ? fn(t) : t)),
});

export const withDelegation = (s: AppState, id: string, patch: Partial<Delegation>): AppState => ({
  ...s,
  delegations: s.delegations.map((d) => (d.id === id ? { ...d, ...patch, updatedAt: demoNow() } : d)),
});

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
  toasts: [...s.toasts, { ...t, id: ++toastSeq }].slice(-3),
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
    next = { ...next, asks: next.asks.filter((a) => !(a.kind === 'takeover' && a.botId === botId)) };
    return withItem(next, botId, { role: 'system', text: '你接管了云桌面，助手暂停操作', at: demoNow() });
  });
}

/** `display.lease.release`: the bot re-captures the screen and continues. */
export function handBack(botId: string) {
  setState((s) => {
    const next = withScreen(s, botId, { control: 'bot', handedBackAt: demoNow(), needsHuman: undefined });
    return withItem(next, botId, { role: 'system', text: '你把云桌面交还给了助手', at: demoNow() });
  });
}

/** `display.start`: screens are off until someone needs them. */
export function startScreen(botId: string) {
  setState((s) => withScreen(s, botId, { running: true, activity: '桌面已启动，空闲中' }));
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
        next = withDelegation(next, 'd2', { state: 'done', note: '已发送' });
      } else if (value === 'edit') {
        next = withItem(next, 'mail', { role: 'assistant', text: '好，草稿放在邮箱的「草稿」里了，你改完直接发就行。', at: demoNow() });
        next = withDelegation(next, 'd2', { state: 'done', note: '草稿交给你修改' });
      } else {
        next = withItem(next, 'mail', { role: 'assistant', text: '好，这封不发了。待办还留着，记得自己回一下。', at: demoNow() });
        next = withDelegation(next, 'd2', { state: 'done', note: '你选择不发' });
      }
      next = withBot(next, 'mail', { status: 'online', statusNote: '下次整理 13:00' });
    }

    if (ask.id === 'ask-hw4') {
      next = withTodo(next, 'td7', (t) => {
        if (value === 'later') return { ...t, proposed: false, doAt: (t.doAt ?? demoNow()) + 86_400_000 };
        if (value === 'self') return { ...t, proposed: false, doAt: undefined };
        return { ...t, proposed: false };
      });
      next = withItem(next, 'study', {
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

export function setSimulate(on: boolean) {
  setState((s) => ({ ...s, simulate: on }));
}

export function setActivityLog(on: boolean) {
  setState((s) => ({ ...s, connection: { ...s.connection, activityLog: on } }));
}

export function dismissToast(id: number) {
  setState((s) => ({ ...s, toasts: s.toasts.filter((t) => t.id !== id) }));
}
