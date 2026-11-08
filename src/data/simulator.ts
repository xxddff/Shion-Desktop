import type { AppState } from './model';
import { nextItemId } from './seed';
import {
  getState,
  resolvedRequests,
  setState,
  withActivity,
  withBot,
  withFrame,
  withItem,
  withSession,
  withTask,
  withTaskEvent,
  withToast,
} from './store';

/**
 * Stand-in for a live Hermes gateway. It emits frames shaped like the real
 * protocol (message.delta, tool.start/complete, task_events) so every screen
 * can be built and judged before the client is wired up.
 */

const TICK_MS = 300;

type Ctx = { answer: Record<string, unknown> | undefined };
type Step =
  | { kind: 'say'; text: string | ((c: Ctx) => string) }
  | { kind: 'tool'; name: string; args: string; ticks: number; output: string; effect?: (s: AppState) => AppState }
  | { kind: 'wait'; ticks: number };

interface Script {
  sessionId: string;
  botId: string;
  /** rpc id of the server request that must be answered before the script runs */
  gate?: string;
  steps: Step[];
}

interface Runner {
  script: Script;
  idx: number;
  progress: number;
  itemId?: string;
  chars?: string[];
}

const heartbeat = (taskId: string, note: string) => (s: AppState) =>
  withTaskEvent(s, taskId, 'heartbeat', { note }, { lastHeartbeatAt: Date.now(), heartbeatNote: note });

const createSubtask = (id: string, title: string, assignee: string) => (s: AppState) => {
  if (s.tasks.some((t) => t.id === id)) return s;
  const now = Date.now();
  let next: AppState = {
    ...s,
    tasks: [
      ...s.tasks,
      {
        id,
        board: 'default',
        title,
        body: '由 Atlas 从 t_3d55 拆出。',
        assignee,
        status: 'todo',
        priority: 1,
        parents: ['t_3d55'],
        workspace: 'scratch',
        skills: [],
        createdBy: 'atlas',
        createdAt: now,
        updatedAt: now,
        comments: [],
        events: [],
        runs: [],
      },
    ],
  };
  next = withTaskEvent(next, id, 'created', { assignee, status: 'todo', parents: ['t_3d55'] });
  return withActivity(next, { tone: 'neutral', botId: 'atlas', taskId: id, text: `Atlas 创建子任务 ${id}「${title}」` });
};

const completeTask = (taskId: string, botId: string, summary: string, to: 'done' | 'review' = 'done') => (s: AppState) => {
  const now = Date.now();
  let next = withTask(s, taskId, (t) => ({
    ...t,
    runs: t.runs.map((r) => (r.outcome === 'running' ? { ...r, outcome: 'completed', endedAt: now, summary } : r)),
  }));
  next = withTaskEvent(next, taskId, to === 'done' ? 'completed' : 'status', to === 'done' ? { result_len: summary.length * 9, summary } : { status: 'review' }, {
    status: to,
    lastHeartbeatAt: undefined,
  });
  next = withBot(next, botId, (b) => ({ ...b, status: 'online', statusNote: '等待新任务' }));
  const name = next.bots.find((b) => b.id === botId)?.displayName ?? botId;
  next = withActivity(next, { tone: 'good', botId, taskId, text: `${name} ${to === 'done' ? '完成' : '提交待审'} ${taskId}：${summary}` });
  return withToast(next, { tone: 'good', title: `${name} ${to === 'done' ? '完成了' : '提交了'} ${taskId}`, body: summary, href: `#task-${taskId}` });
};

const scripts: Script[] = [
  {
    sessionId: 's_coder_k1',
    botId: 'coder',
    gate: 'srv_51',
    steps: [
      {
        kind: 'say',
        text: (c) =>
          c.answer?.choice === 'deny'
            ? '收到拒绝，不改写远端历史。我把改动推到新分支 feat/gateway-client-2，然后继续写断线重连。'
            : '推送完成。现在补断线重连：ticket 是一次性的，重连前先用 hermes gateway attach --recover 换一张新的。',
      },
      { kind: 'tool', name: 'write_file', args: 'src/gateway/reconnect.ts', ticks: 5, output: '+88 行' },
      { kind: 'say', text: '重连后调用 session.events.since：open_requests 用来恢复还没回复的审批，inflight 用来接上正在流式输出的回复。' },
      { kind: 'tool', name: 'terminal', args: 'npm test -- gateway', ticks: 12, output: '12 passed · 0 failed' },
      {
        kind: 'tool',
        name: 'kanban_heartbeat',
        args: '{"note":"断线重连完成，测试通过"}',
        ticks: 2,
        output: 'ok',
        effect: heartbeat('t_7a10', '断线重连完成，测试通过'),
      },
      { kind: 'say', text: '下一步写兜底：宿主没实现的 server request 要立刻回 -32601，别让 agent 干等。' },
      { kind: 'tool', name: 'write_file', args: 'src/gateway/requests.ts', ticks: 5, output: '+41 行' },
    ],
  },
  {
    sessionId: 's_atlas_tg',
    botId: 'atlas',
    gate: 'srv_52',
    steps: [
      {
        kind: 'say',
        text: (c) =>
          `${typeof c.answer?.answer === 'string' ? `好，按「${c.answer.answer}」来。` : '那我先按最小范围做。'}第二张：收件箱的系统通知，点通知直接跳到对应请求。`,
      },
      {
        kind: 'tool',
        name: 'kanban_create',
        args: '{"title":"收件箱：系统通知与跳转","assignee":"coder","parents":["t_3d55"]}',
        ticks: 3,
        output: 't_c4e2',
        effect: createSubtask('t_c4e2', '收件箱：系统通知与跳转', 'coder'),
      },
      { kind: 'say', text: '第三张是键盘操作：⌘↩ 批准、⌘⌫ 拒绝。先让 Scribe 写交互说明。' },
      {
        kind: 'tool',
        name: 'kanban_create',
        args: '{"title":"收件箱：键盘操作说明","assignee":"scribe","parents":["t_3d55"]}',
        ticks: 3,
        output: 't_c4e3',
        effect: createSubtask('t_c4e3', '收件箱：键盘操作说明', 'scribe'),
      },
      { kind: 'say', text: '三张子任务都建好了，t_3d55 我标记完成。' },
      {
        kind: 'tool',
        name: 'kanban_complete',
        args: '{"task":"t_3d55","summary":"拆成 3 张子任务"}',
        ticks: 2,
        output: 'ok',
        effect: completeTask('t_3d55', 'atlas', '拆成 3 张子任务'),
      },
    ],
  },
  {
    sessionId: 's_scout_k1',
    botId: 'scout',
    steps: [
      { kind: 'wait', ticks: 6 },
      { kind: 'tool', name: 'web_search', args: 'hermes kanban plugin graph view', ticks: 6, output: '9 条结果' },
      { kind: 'say', text: '找到 kanban-graph 插件的更新：任务依赖可以画成图。记一条。' },
      { kind: 'tool', name: 'web_fetch', args: 'hermes-agent.nousresearch.com/docs/plugins/kanban-graph', ticks: 5, output: '读取完成' },
      { kind: 'tool', name: 'kanban_heartbeat', args: '{"note":"已收集 8 条"}', ticks: 2, output: 'ok', effect: heartbeat('t_4b09', '已收集 8 条') },
      { kind: 'say', text: '再看一眼社区里关于移动端插件的讨论，然后收尾。' },
      { kind: 'tool', name: 'web_search', args: 'hermes mobile plugin websocket', ticks: 6, output: '11 条结果' },
      { kind: 'say', text: '一共 9 条，按「官方 / 社区」分组写进结果。' },
      {
        kind: 'tool',
        name: 'kanban_complete',
        args: '{"task":"t_4b09","summary":"本周插件动态 9 条"}',
        ticks: 3,
        output: 'ok',
        effect: (s) => withSession(completeTask('t_4b09', 'scout', '本周插件动态 9 条')(s), 's_scout_k1', (x) => ({ ...x, live: false })),
      },
    ],
  },
];

const runners: Runner[] = scripts.map((script) => ({ script, idx: 0, progress: 0 }));
/** task id → tick it was claimed by the simulated dispatcher */
const autoClaimed = new Map<string, number>();
let tick = 0;

function stepRunner(s: AppState, r: Runner): AppState {
  const { script } = r;
  if (r.idx >= script.steps.length) return s;
  if (script.gate && !resolvedRequests.has(script.gate)) return s;
  const step = script.steps[r.idx];
  const sid = script.sessionId;
  const ctx: Ctx = { answer: script.gate ? resolvedRequests.get(script.gate) : undefined };
  let next = withBot(s, script.botId, (b) => ({ ...b, lastActiveAt: Date.now() }));

  if (step.kind === 'wait') {
    if (++r.progress >= step.ticks) {
      r.idx++;
      r.progress = 0;
    }
    return next;
  }

  if (step.kind === 'say') {
    if (!r.itemId) {
      r.itemId = nextItemId();
      r.chars = Array.from(typeof step.text === 'function' ? step.text(ctx) : step.text);
      r.progress = 0;
      next = withItem(next, sid, { id: r.itemId, role: 'assistant', at: Date.now(), text: '', streaming: true });
    }
    const item = next.sessions[sid]?.items.find((i) => i.id === r.itemId);
    const interrupted = item && item.streaming === false;
    const chars = r.chars ?? [];
    if (!interrupted && r.progress < chars.length) {
      const chunk = chars.slice(r.progress, r.progress + 4).join('');
      r.progress += 4;
      next = withSession(next, sid, (x) => ({
        ...x,
        tokens: x.tokens + 11,
        items: x.items.map((i) => (i.id === r.itemId ? { ...i, text: (i.text ?? '') + chunk } : i)),
      }));
      next = withBot(next, script.botId, (b) => ({ ...b, tokensToday: b.tokensToday + 11, costToday: b.costToday + 0.00004 }));
      return withFrame(next, { dir: 'in', channel: 'gateway', kind: 'event', method: 'message.delta', payload: { session_id: sid, text: chunk } });
    }
    next = withSession(next, sid, (x) => ({ ...x, items: x.items.map((i) => (i.id === r.itemId ? { ...i, streaming: false } : i)) }));
    next = withFrame(next, { dir: 'in', channel: 'gateway', kind: 'event', method: 'message.complete', payload: { session_id: sid } });
    r.idx++;
    r.itemId = undefined;
    return next;
  }

  // tool
  if (!r.itemId) {
    r.itemId = nextItemId();
    r.progress = 0;
    next = withItem(next, sid, { id: r.itemId, role: 'tool', at: Date.now(), tool: { name: step.name, args: step.args, status: 'running' } });
    return withFrame(next, {
      dir: 'in',
      channel: 'gateway',
      kind: 'event',
      method: 'tool.start',
      payload: { session_id: sid, tool_id: r.itemId, name: step.name, args: step.args },
    });
  }
  if (++r.progress < step.ticks) return next;
  const durationMs = step.ticks * TICK_MS + Math.round(Math.random() * 200);
  next = withSession(next, sid, (x) => ({
    ...x,
    items: x.items.map((i) => (i.id === r.itemId && i.tool ? { ...i, tool: { ...i.tool, status: 'done', durationMs, output: step.output } } : i)),
  }));
  next = withFrame(next, {
    dir: 'in',
    channel: 'gateway',
    kind: 'event',
    method: 'tool.complete',
    payload: { session_id: sid, tool_id: r.itemId, ok: true, duration_ms: durationMs },
  });
  if (step.effect) next = step.effect(next);
  r.idx++;
  r.itemId = undefined;
  return next;
}

/** A pocket version of the kanban dispatcher: claim ready cards for free bots. */
function dispatch(s: AppState): AppState {
  let next = s;
  for (const t of s.tasks) {
    if (t.status !== 'ready' || !t.assignee) continue;
    const bot = next.bots.find((b) => b.id === t.assignee);
    if (!bot || (bot.status !== 'online' && bot.status !== 'idle')) continue;
    if (next.tasks.some((x) => x.assignee === bot.id && x.status === 'running')) continue;
    const runId = `r_${t.id.slice(2)}_${t.runs.length + 1}`;
    next = withTask(next, t.id, (x) => ({ ...x, runs: [...x.runs, { id: runId, profile: bot.id, outcome: 'running', startedAt: Date.now() }] }));
    next = withTaskEvent(next, t.id, 'claimed', { lock: `${bot.id}@mbp`, expires: '15m' }, { status: 'running', lastHeartbeatAt: Date.now(), heartbeatNote: '刚认领' });
    next = withBot(next, bot.id, (b) => ({ ...b, status: 'working', statusNote: `${t.id} · ${t.title}`, lastActiveAt: Date.now() }));
    next = withActivity(next, { tone: 'info', botId: bot.id, taskId: t.id, text: `${bot.displayName} 认领 ${t.id}` });
    autoClaimed.set(t.id, tick);
  }
  return next;
}

function onTick() {
  const s0 = getState();
  if (!s0.simulate) return;
  tick++;
  setState((s) => {
    let next = s;
    for (const r of runners) next = stepRunner(next, r);

    if (tick % 40 === 0) next = dispatch(next);

    // dispatcher-claimed cards finish after ~30s and go to review
    for (const [taskId, at] of autoClaimed) {
      if (tick - at >= 100) {
        const t = next.tasks.find((x) => x.id === taskId);
        autoClaimed.delete(taskId);
        if (t?.status === 'running' && t.assignee) next = completeTask(taskId, t.assignee, '初稿完成，请审阅', 'review')(next);
      }
    }

    if (tick % 50 === 0) {
      for (const t of next.tasks.filter((x) => x.status === 'running')) {
        next = withTaskEvent(next, t.id, 'heartbeat', { note: t.heartbeatNote }, { lastHeartbeatAt: Date.now() });
      }
    }

    if (tick === 12 && next.inbox.some((r) => r.rpcId === 'srv_51')) {
      next = withToast(next, { tone: 'warning', title: 'Coder 在等你批准', body: 'git push --force-with-lease', href: '#inbox' });
    }

    if (tick % 10 === 0) {
      next = { ...next, connection: { ...next.connection, latencyMs: 3 + Math.round(Math.random() * 6) } };
    }
    return next;
  });
}

export function startSimulator(): () => void {
  const id = window.setInterval(onTick, TICK_MS);
  return () => window.clearInterval(id);
}
