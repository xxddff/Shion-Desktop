import { at, demoNow } from './clock';
import type { AppState } from './model';
import { nextId } from './seed';
import {
  getState,
  replyQueue,
  setState,
  withBlock,
  withBot,
  withClaim,
  withComplete,
  withItem,
  withScreen,
  withToast,
  withTodo,
} from './store';

/**
 * Plays out the next few minutes of the demo day on the kanban board:
 * 「课程」 finishes card t_c7a1 and 紫苑 (subscribed to cards she creates) asks
 * you about dates; t_c7b2 hits two-step sign-in on the cloud desktop and
 * blocks until you take over; 「资讯」 finishes its fact-check card.
 */

const TICK_MS = 300;

type Step =
  | { kind: 'say'; text: string; todoIds?: string[] }
  | { kind: 'tool'; summary: string; tool: string; ticks: number; effect?: (s: AppState) => AppState }
  | { kind: 'effect'; run: (s: AppState) => AppState }
  | { kind: 'wait'; ticks: number }
  | { kind: 'until'; test: (s: AppState) => boolean };

interface Runner {
  /** Chat key the steps write to: a bot id or `w:<card id>`. */
  chat: string;
  botId: string;
  steps: Step[];
  idx: number;
  progress: number;
  itemId?: string;
  chars?: string[];
}

const run = (chat: string, botId: string, steps: Step[]): Runner => ({ chat, botId, steps, idx: 0, progress: 0 });

const studyTodos = (s: AppState): AppState => {
  if (s.todos.some((t) => t.id === 'td7')) return s;
  const src = { kind: 'class' as const, label: '数据结构与算法 第7回' };
  return {
    ...s,
    todos: [
      ...s.todos,
      { id: 'td7', title: '数据结构 作业4：实现二叉堆', area: 'study', source: src, doAt: at(2, 19), dueAt: at(4, 23, 59), done: false, nudges: 0, proposed: true, notes: '录音 41:20 处：「作业4 下周五晚上 12 点前交，要求用数组实现，附测试。」' },
      { id: 'td8', title: '复习第7回：堆与优先队列', area: 'study', source: src, doAt: at(1, 20), done: false, nudges: 0, proposed: true },
      { id: 'td13', title: '读教材 7.3 节（下次课前）', area: 'study', source: src, doAt: at(1, 21), dueAt: at(2, 9), done: false, nudges: 0, proposed: true },
    ],
  };
};

/** 紫苑 is subscribed to the cards she creates: a terminal event wakes her Bot Chat. */
const notifyShion = (cardId: string, text: string, extra: { todoIds?: string[] } = {}) => (s: AppState): AppState => {
  let next = withItem(s, 'shion', { role: 'card', at: demoNow(), cardId });
  next = withItem(next, 'shion', { role: 'assistant', text, at: demoNow(), ...extra });
  const open = next.cards.filter((c) => c.createdBy === 'shion' && c.status !== 'done').length;
  return withBot(next, 'shion', { lastActiveAt: demoNow(), statusNote: open ? `在跟进 ${open} 件事` : '没有在跟进的事' });
};

const scripts: Runner[] = [
  // card t_c7a1: list what the class asks of you
  run('w:t_c7a1', 'study', [
    { kind: 'wait', ticks: 4 },
    {
      kind: 'say',
      text: '第7回讲了堆和优先队列。录音里老师提到 3 件要做的事：作业4（用数组实现二叉堆，附测试）周五 23:59 截止；下次课前读教材 7.3 节；期中考试范围到第8回。',
    },
    { kind: 'tool', summary: '把 3 件事写进了待办，日期先标成建议', tool: 'shion.todos.propose', ticks: 4, effect: studyTodos },
    {
      kind: 'tool',
      summary: '交付：3 件待办，作业4 建议周三 19:00 做',
      tool: 'kanban_complete',
      ticks: 3,
      effect: (s) => {
        let next = withComplete(s, 't_c7a1', '3 件待办提案，作业4 建议周三 19:00 做');
        next = notifyShion('t_c7a1', '「课程」整理完第7回了，3 件事放进了待办。作业4 我排在周三 19:00，那天只有两节课，离周五 23:59 截止还空出一天。这样可以吗？', {
          todoIds: ['td7', 'td8', 'td13'],
        })(next);
        next = {
          ...next,
          asks: [
            ...next.asks,
            {
              id: 'ask-hw4',
              kind: 'clarify',
              botId: 'shion',
              at: demoNow(),
              title: '作业4 排在周三 19:00 做，周五 23:59 截止，可以吗？',
              detail: '来自第7回录音的整理。',
              options: [
                { label: '可以', value: 'ok', primary: true },
                { label: '往后挪一天', value: 'later' },
                { label: '我自己安排', value: 'self' },
              ],
              todoId: 'td7',
            },
          ],
        };
        next = withBot(next, 'study', { status: 'online', statusNote: '接下来下载第7回课件' });
        return withToast(next, { title: '「课程」整理完了第7回', body: '新增 3 件待办，作业4 的日期等你确认', botId: 'study', href: '#chat-shion' });
      },
    },
    // the dispatcher picks up the next card for the same assistant
    { kind: 'wait', ticks: 10 },
    {
      kind: 'effect',
      run: (s) => {
        let next = withClaim(s, 't_c7b2');
        next = withScreen(next, 'study', { running: true, app: 'sso', url: 'sso.univ.example/login', activity: '打开课程平台，跳到了学校统一认证' });
        next = withItem(next, 'w:t_c7b2', { role: 'tool', at: demoNow(), tool: { summary: '在云桌面上打开课程平台，准备下载第7回课件', tool: 'browser.navigate', status: 'done' } });
        return withBot(next, 'study', { status: 'working', statusNote: '在云桌面上打开课程平台' });
      },
    },
  ]),
  // card t_c7b2: the slides, which need you for two-step sign-in
  run('w:t_c7b2', 'study', [
    { kind: 'until', test: (s) => s.cards.find((c) => c.id === 't_c7b2')?.status === 'running' },
    { kind: 'wait', ticks: 6 },
    { kind: 'say', text: '课程平台跳到了学校统一认证，要两步验证，这一步得你来。我先停在登录页，你登录一次，登录状态会留在云桌面的浏览器里。' },
    {
      kind: 'tool',
      summary: '停下来等你：需要在云桌面上完成两步验证',
      tool: 'kanban_block',
      ticks: 2,
      effect: (s) => {
        let next = withBlock(s, 't_c7b2', { kind: 'needs_input', reason: '需要你在云桌面上完成学校统一认证的两步验证' });
        next = withScreen(next, 'study', { needsHuman: '学校统一认证要两步验证', activity: '停在登录页，等你接管' });
        next = {
          ...next,
          asks: [
            ...next.asks,
            {
              id: 'ask-sso',
              kind: 'takeover',
              botId: 'study',
              at: demoNow(),
              title: '学校统一认证要两步验证，需要你在云桌面上登录一次',
              detail: '下载课件卡在这一步。接管后登录、在手机上确认，然后交还，它会接着做。',
              options: [
                { label: '去接管', value: 'go', primary: true },
                { label: '稍后', value: 'later' },
              ],
              cardId: 't_c7b2',
            },
          ],
        };
        next = withBot(next, 'study', { status: 'blocked', statusNote: '等你接管云桌面' });
        return withToast(next, { title: '「课程」需要你接管云桌面', body: '学校统一认证要两步验证', botId: 'study', href: '#desktop-study' });
      },
    },
    // you take over, sign in and hand back: the card goes to ready and is re-run with your comment
    { kind: 'until', test: (s) => s.cards.find((c) => c.id === 't_c7b2')?.status === 'ready' },
    { kind: 'wait', ticks: 4 },
    {
      kind: 'effect',
      run: (s) => {
        let next = withClaim(s, 't_c7b2');
        next = withScreen(next, 'study', { app: 'moodle', url: 'lms.univ.example/course/ds/week7', activity: '在下载第7回课件' });
        return withBot(next, 'study', { status: 'working', statusNote: '在下载第7回课件' });
      },
    },
    { kind: 'tool', summary: '下载了第7回课件（PDF，3.2 MB），存进 Notion「数据结构与算法」', tool: 'browser.download', ticks: 8 },
    {
      kind: 'tool',
      summary: '交付：课件已存进 Notion',
      tool: 'kanban_complete',
      ticks: 2,
      effect: (s) => {
        let next = withComplete(s, 't_c7b2', '第7回课件已存进 Notion');
        next = notifyShion('t_c7b2', '第7回课件也存进 Notion 了，接下来做复习卡片。')(next);
        next = withScreen(next, 'study', { activity: '空闲中' });
        next = withBot(next, 'study', { status: 'online', statusNote: '接下来做复习卡片' });
        return withToast(next, { title: '「课程」下载好了第7回课件', body: '已存进 Notion', botId: 'study', href: '#board' });
      },
    },
    // its child card t_c7c3 was waiting on it; the dispatcher claims it on the next tick
    { kind: 'wait', ticks: 12 },
    {
      kind: 'effect',
      run: (s) => withBot(withClaim(s, 't_c7c3'), 'study', { status: 'working', statusNote: '在做第7回复习卡片' }),
    },
  ]),
  run('w:t_c7c3', 'study', [
    { kind: 'until', test: (s) => s.cards.find((c) => c.id === 't_c7c3')?.status === 'running' },
    { kind: 'tool', summary: '读了 Notion 里的第7回课件和录音要点', tool: 'notion.fetch_page', ticks: 6 },
    { kind: 'tool', summary: '做了 14 张问答卡片，存进 Notion「数据结构与算法」第7回', tool: 'notion.append_blocks', ticks: 8 },
    {
      kind: 'tool',
      summary: '交付：14 张复习卡片',
      tool: 'kanban_complete',
      ticks: 2,
      effect: (s) => {
        let next = withComplete(s, 't_c7c3', '14 张复习卡片已存进 Notion');
        next = notifyShion('t_c7c3', '第7回的复习卡片也做好了，14 张。我把「复习第7回」排在明天 20:00，到时候提醒你。')(next);
        return withBot(next, 'study', { status: 'online', statusNote: '下一节 13:00 机器学习基础' });
      },
    },
  ]),
  // card t_f1e0: fact-check
  run('w:t_f1e0', 'news', [
    { kind: 'wait', ticks: 70 },
    { kind: 'tool', summary: '读了 电力公司 和 主管部门 的公告', tool: 'web.fetch', ticks: 6 },
    {
      kind: 'say',
      text: '结论：说法不准确。电力公司 12 月的标准家庭电费比 11 月高约 4%，主要因为政府补贴结束。「30%」是拿去年补贴期间的最低月份和今年的峰值比出来的，口径不同。',
    },
    {
      kind: 'tool',
      summary: '交付：不准确，实际约 +4%',
      tool: 'kanban_complete',
      ticks: 2,
      effect: (s) => {
        let next = withComplete(s, 't_f1e0', '不准确：实际约 +4%，「30%」口径不同');
        next = { ...next, news: next.news.map((n) => (n.check === 'disputed' ? { ...n, checkNote: '不准确：实际约 +4%，口径不同' } : n)) };
        next = notifyShion('t_f1e0', '电费那条查完了：上涨 30% 的说法不准确，12 月实际比 11 月高约 4%，主要是补贴结束。「30%」是拿不同口径的月份比出来的。')(next);
        next = withBot(next, 'news', { status: 'idle', statusNote: '下次 明天 07:00' });
        next = withScreen(next, 'news', { activity: '空闲中' });
        return withToast(next, { title: '「资讯」核实完了电费传言', body: '「上涨 30%」不准确，实际约 +4%', botId: 'news', href: '#chat-shion' });
      },
    },
  ]),
  // 紫苑's noon nudge
  run('shion', 'shion', [
    { kind: 'wait', ticks: 40 },
    {
      kind: 'effect',
      run: (s) => {
        const quiz = s.todos.find((t) => t.id === 'td2');
        if (!quiz || quiz.done) return s;
        let next = withTodo(s, 'td2', (t) => ({ ...t, nudges: t.nudges + 1 }));
        next = withItem(next, 'shion', {
          role: 'assistant',
          text: '提醒一下：「机器学习 课前小测」12:50 截止，大概 15 分钟能做完。现在做，做完正好去吃午饭？',
          at: demoNow(),
          todoIds: ['td2'],
        });
        return withToast(next, { title: '紫苑：课前小测 12:50 截止', body: '大概 15 分钟，做完再去吃饭？', botId: 'shion', href: '#todos' });
      },
    },
  ]),
];

const runners: Runner[] = scripts;
let cardSeq = 0x3a0;

function replyFor(botId: string, text: string): Step[] {
  if (botId === 'shion') {
    if (/核实|真的吗|查一下|是不是|调研|找一下/.test(text)) {
      const id = `t_${(++cardSeq).toString(16)}`;
      return [
        { kind: 'say', text: '好，交给「资讯」去查，有结论我回来告诉你。' },
        {
          kind: 'effect',
          run: (s) => {
            const next: AppState = {
              ...s,
              cards: [
                ...s.cards,
                {
                  id,
                  title: `核实：${text.slice(0, 24)}`,
                  body: `用户的原话：「${text}」。找可靠来源，结论写清楚依据。`,
                  assignee: 'news',
                  createdBy: 'shion',
                  status: 'ready',
                  comments: [],
                  runs: [],
                  createdAt: demoNow(),
                  updatedAt: demoNow(),
                },
              ],
            };
            return withItem(next, 'shion', { role: 'card', at: demoNow(), cardId: id });
          },
        },
      ];
    }
    if (/明天/.test(text)) return [{ kind: 'say', text: '明天第一节是 10:40 的线性代数，下午 14:00 去实习。待办 2 件：写实习周报（18:00 截止，排在上午 10:00）、复习第7回（晚上 20:00）。' }];
    return [{ kind: 'say', text: '收到，记下了。需要排时间的话，我会放进今天的安排，到点提醒你。' }];
  }
  if (botId === 'commute') return [{ kind: 'say', text: '现在 中央線快速 正常运行。18:10 从新宿出发，18:42 到吉祥寺。' }];
  return [{ kind: 'say', text: '收到，我来处理，好了告诉你。' }];
}

function patchItem(s: AppState, key: string, id: string, fn: (i: AppState['chats'][string]['items'][number]) => AppState['chats'][string]['items'][number]): AppState {
  const chat = s.chats[key];
  return { ...s, chats: { ...s.chats, [key]: { ...chat, items: chat.items.map((i) => (i.id === id ? fn(i) : i)) } } };
}

function stepRunner(s: AppState, r: Runner): AppState {
  if (r.idx >= r.steps.length) return s;
  const step = r.steps[r.idx];
  if (step.kind === 'until') {
    if (step.test(s)) r.idx++;
    return s;
  }
  if (step.kind === 'wait') {
    if (++r.progress >= step.ticks) {
      r.idx++;
      r.progress = 0;
    }
    return s;
  }
  if (step.kind === 'effect') {
    r.idx++;
    return step.run(s);
  }
  let next = withBot(s, r.botId, { lastActiveAt: demoNow() });
  if (step.kind === 'say') {
    if (!r.itemId) {
      const id = nextId();
      r.itemId = id;
      r.chars = Array.from(step.text);
      r.progress = 0;
      next = withItem(next, r.chat, { role: 'assistant', text: '', at: demoNow(), streaming: true, todoIds: step.todoIds });
      const items = next.chats[r.chat].items;
      r.itemId = items[items.length - 1].id;
    }
    const id = r.itemId;
    const chars = r.chars ?? [];
    if (r.progress < chars.length) {
      const chunk = chars.slice(r.progress, r.progress + 5).join('');
      r.progress += 5;
      return patchItem(next, r.chat, id, (i) => ({ ...i, text: (i.text ?? '') + chunk }));
    }
    r.idx++;
    r.itemId = undefined;
    return patchItem(next, r.chat, id, (i) => ({ ...i, streaming: false }));
  }
  // tool
  if (!r.itemId) {
    r.progress = 0;
    next = withItem(next, r.chat, { role: 'tool', at: demoNow(), tool: { summary: step.summary, tool: step.tool, status: 'running' } });
    const items = next.chats[r.chat].items;
    r.itemId = items[items.length - 1].id;
    return next;
  }
  if (++r.progress < step.ticks) return next;
  const id = r.itemId;
  next = patchItem(next, r.chat, id, (i) => (i.tool ? { ...i, tool: { ...i.tool, status: 'done' } } : i));
  r.idx++;
  r.itemId = undefined;
  return step.effect ? step.effect(next) : next;
}

function onTick() {
  if (!getState().simulate) return;
  setState((s) => {
    let next = s;
    for (const r of runners) next = stepRunner(next, r);
    const msg = replyQueue.shift();
    if (msg) runners.push(run(msg.botId, msg.botId, [{ kind: 'wait', ticks: 3 }, ...replyFor(msg.botId, msg.text)]));
    if (Math.random() < 0.03) next = { ...next, connection: { ...next.connection, latencyMs: 18 + Math.round(Math.random() * 12) } };
    return next;
  });
}

export function startSimulator(): () => void {
  const id = window.setInterval(onTick, TICK_MS);
  return () => window.clearInterval(id);
}
