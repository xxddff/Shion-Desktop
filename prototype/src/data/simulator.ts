import { at, demoNow } from './clock';
import type { AppState } from './model';
import { nextId } from './seed';
import { getState, replyQueue, setState, withBot, withDelegation, withItem, withScreen, withToast, withTodo } from './store';

/**
 * Plays out the next few minutes of the demo day: 「课程」 finishes the class
 * summary and proposes todos, 「资讯」 finishes a fact-check, 紫苑 nudges you
 * about a deadline, and every message you send gets an answer.
 */

const TICK_MS = 300;

type Step =
  | { kind: 'say'; text: string; todoIds?: string[] }
  | { kind: 'tool'; summary: string; tool: string; ticks: number; effect?: (s: AppState) => AppState }
  | { kind: 'effect'; run: (s: AppState) => AppState }
  | { kind: 'wait'; ticks: number }
  | { kind: 'until'; test: (s: AppState) => boolean };

interface Runner {
  botId: string;
  steps: Step[];
  idx: number;
  progress: number;
  itemId?: string;
  chars?: string[];
}

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

const scripts: Runner[] = [
  {
    botId: 'study',
    idx: 0,
    progress: 0,
    steps: [
      { kind: 'wait', ticks: 4 },
      {
        kind: 'say',
        text: '第7回讲了堆和优先队列。录音里老师提到 3 件要你做的事：作业4（用数组实现二叉堆，附测试）周五 23:59 截止；下次课前读教材 7.3 节；期中考试范围到第8回。',
      },
      { kind: 'tool', summary: '在待办里新建了 3 件事，日期等你确认', tool: 'shion.todos.propose', ticks: 4, effect: studyTodos },
      { kind: 'say', text: '作业4 我排在周三晚上 19:00 做，那天只有两节课，截止前还空出一天。这样可以吗？', todoIds: ['td7', 'td8', 'td13'] },
      {
        kind: 'effect',
        run: (s) => {
          let next: AppState = {
            ...s,
            asks: [
              ...s.asks,
              {
                id: 'ask-hw4',
                kind: 'clarify',
                botId: 'study',
                at: demoNow(),
                title: '作业4 排在周三 19:00 做，周五 23:59 截止，可以吗？',
                detail: '来自「数据结构与算法 第7回」的录音整理。',
                options: [
                  { label: '可以', value: 'ok', primary: true },
                  { label: '往后挪一天', value: 'later' },
                  { label: '我自己安排', value: 'self' },
                ],
                todoId: 'td7',
              },
            ],
          };
          next = withDelegation(next, 'd3', { state: 'done', note: '3 件待办等你确认日期' });
          next = withBot(next, 'study', { status: 'online', statusNote: '下一节 13:00 机器学习基础' });
          next = withItem(next, 'shion', { role: 'assistant', text: '「课程」整理完了：3 件事已经放进待办，作业4 的日期等你确认。', at: demoNow() });
          return withToast(next, { title: '课程 整理完第7回', body: '新增 3 件待办，作业4 的日期等你确认', botId: 'study', href: '#confirm' });
        },
      },
      // then it fetches the slides from the course site on its cloud desktop and hits two-step sign-in
      { kind: 'wait', ticks: 16 },
      {
        kind: 'effect',
        run: (s) => {
          let next = withScreen(s, 'study', { running: true, app: 'sso', url: 'sso.univ.example/login', activity: '打开课程平台，跳到了学校统一认证' });
          next = withItem(next, 'study', { role: 'tool', at: demoNow(), tool: { summary: '在云桌面上打开课程平台，准备下载第7回课件', tool: 'browser.navigate', status: 'done' } });
          return withBot(next, 'study', { status: 'working', statusNote: '在云桌面上：课程平台' });
        },
      },
      { kind: 'wait', ticks: 8 },
      {
        kind: 'effect',
        run: (s) => {
          let next = withScreen(s, 'study', { needsHuman: '学校统一认证要两步验证', activity: '停在登录页，等你接管' });
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
                detail: '接管后登录、在手机上确认，然后点「交还」。登录状态会留在它的浏览器里，以后不用再登录。',
                options: [
                  { label: '去接管', value: 'go', primary: true },
                  { label: '稍后', value: 'later' },
                ],
              },
            ],
          };
          next = withItem(next, 'study', { role: 'assistant', text: '课程平台跳到了学校统一认证，要两步验证，这一步得你来。我停在登录页了，你接管登录一下，好了点「交还」，我接着下载课件。', at: demoNow() });
          next = withBot(next, 'study', { status: 'blocked', statusNote: '等你接管云桌面：两步验证' });
          return withToast(next, { title: '课程 需要你接管云桌面', body: '学校统一认证要两步验证', botId: 'study', href: '#desktop-study' });
        },
      },
      { kind: 'until', test: (s) => s.screens.study?.handedBackAt != null && s.screens.study.control === 'bot' },
      { kind: 'wait', ticks: 4 },
      {
        kind: 'effect',
        run: (s) => {
          const next = withScreen(s, 'study', { app: 'moodle', url: 'lms.univ.example/course/ds/week7', activity: '在下载第7回课件' });
          return withBot(next, 'study', { status: 'working', statusNote: '在云桌面上下载第7回课件' });
        },
      },
      { kind: 'tool', summary: '下载了第7回课件（PDF，3.2 MB），存进 Notion「数据结构与算法」', tool: 'browser.download', ticks: 8 },
      { kind: 'say', text: '课件存好了。登录状态留在云桌面的浏览器里，之后去课程平台不用再登录。' },
      {
        kind: 'effect',
        run: (s) => {
          const next = withScreen(s, 'study', { activity: '空闲中' });
          return withBot(next, 'study', { status: 'online', statusNote: '下一节 13:00 机器学习基础' });
        },
      },
    ],
  },
  {
    botId: 'news',
    idx: 0,
    progress: 0,
    steps: [
      { kind: 'wait', ticks: 70 },
      { kind: 'tool', summary: '读了 电力公司 和 主管部门 的公告', tool: 'web.fetch', ticks: 6 },
      {
        kind: 'say',
        text: '结论：说法不准确。电力公司 12 月的标准家庭电费比 11 月高约 4%，主要因为政府补贴结束。「30%」是拿去年补贴期间的最低月份和今年的峰值比出来的，口径不同。',
      },
      {
        kind: 'effect',
        run: (s) => {
          let next = withDelegation(s, 'd1', { state: 'done', note: '不准确：实际约 +4%' });
          next = {
            ...next,
            news: next.news.map((n) => (n.check === 'disputed' ? { ...n, checkNote: '不准确：实际约 +4%，口径不同' } : n)),
          };
          next = withBot(next, 'news', { status: 'idle', statusNote: '下次 明天 07:00' });
          next = withScreen(next, 'news', { activity: '空闲中' });
          next = withItem(next, 'shion', { role: 'assistant', text: '「资讯」核实完了：电费上涨 30% 的说法不准确，实际约 4%。细节在它的对话里。', at: demoNow() });
          return withToast(next, { title: '资讯 核实完了', body: '「电费上涨 30%」不准确，实际约 +4%', botId: 'news', href: '#chat-news' });
        },
      },
    ],
  },
  {
    botId: 'shion',
    idx: 0,
    progress: 0,
    steps: [
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
    ],
  },
];

const runners: Runner[] = scripts;

function replyFor(botId: string, text: string): { text: string; handoff?: string } {
  if (botId === 'shion') {
    if (/核实|真的吗|查一下|是不是/.test(text)) return { text: '好，交给「资讯」去核实，有结论了告诉你。', handoff: 'news' };
    if (/明天/.test(text)) return { text: '明天第一节是 10:40 的线性代数，下午 14:00 去实习。待办 2 件：写实习周报（18:00 截止，排在上午 10:00）、复习第7回（晚上 20:00）。' };
    if (/邮件|回信|回复/.test(text)) return { text: '交给「邮件」处理，发出去之前会先问你。', handoff: 'mail' };
    if (/车|出门|路线|电车|巴士/.test(text)) return { text: '我让「通勤」查一下，马上给你路线。', handoff: 'commute' };
    return { text: '收到，记下了。需要排时间的话，我会放进今天的安排，到点提醒你。' };
  }
  if (botId === 'commute') return { text: '现在 中央線快速 正常运行。18:10 从新宿出发，18:42 到吉祥寺。' };
  return { text: '收到，我来处理，好了告诉你。' };
}

function stepRunner(s: AppState, r: Runner): AppState {
  if (r.idx >= r.steps.length) return s;
  const step = r.steps[r.idx];
  if (step.kind === 'wait') {
    if (++r.progress >= step.ticks) {
      r.idx++;
      r.progress = 0;
    }
    return s;
  }
  if (step.kind === 'until') {
    if (step.test(s)) r.idx++;
    return s;
  }
  if (step.kind === 'effect') {
    r.idx++;
    return step.run(s);
  }
  let next = withBot(s, r.botId, { lastActiveAt: demoNow() });
  if (step.kind === 'say') {
    if (!r.itemId) {
      r.itemId = nextId();
      r.chars = Array.from(step.text);
      r.progress = 0;
      const chat = next.chats[r.botId];
      next = {
        ...next,
        chats: { ...next.chats, [r.botId]: { ...chat, items: [...chat.items, { id: r.itemId, role: 'assistant', text: '', at: demoNow(), streaming: true, todoIds: step.todoIds }] } },
      };
    }
    const chars = r.chars ?? [];
    const id = r.itemId;
    if (r.progress < chars.length) {
      const chunk = chars.slice(r.progress, r.progress + 5).join('');
      r.progress += 5;
      return {
        ...next,
        chats: { ...next.chats, [r.botId]: { ...next.chats[r.botId], items: next.chats[r.botId].items.map((i) => (i.id === id ? { ...i, text: (i.text ?? '') + chunk } : i)) } },
      };
    }
    r.idx++;
    r.itemId = undefined;
    return {
      ...next,
      chats: { ...next.chats, [r.botId]: { ...next.chats[r.botId], items: next.chats[r.botId].items.map((i) => (i.id === id ? { ...i, streaming: false } : i)) } },
    };
  }
  // tool
  if (!r.itemId) {
    r.itemId = nextId();
    r.progress = 0;
    const chat = next.chats[r.botId];
    return {
      ...next,
      chats: { ...next.chats, [r.botId]: { ...chat, items: [...chat.items, { id: r.itemId, role: 'tool', at: demoNow(), tool: { summary: step.summary, tool: step.tool, status: 'running' } }] } },
    };
  }
  if (++r.progress < step.ticks) return next;
  const id = r.itemId;
  next = {
    ...next,
    chats: {
      ...next.chats,
      [r.botId]: { ...next.chats[r.botId], items: next.chats[r.botId].items.map((i) => (i.id === id && i.tool ? { ...i, tool: { ...i.tool, status: 'done' } } : i)) },
    },
  };
  r.idx++;
  r.itemId = undefined;
  return step.effect ? step.effect(next) : next;
}

function onTick() {
  if (!getState().simulate) return;
  setState((s) => {
    let next = s;
    for (const r of runners) next = stepRunner(next, r);
    // answer one queued message by appending a streaming runner
    const msg = replyQueue.shift();
    if (msg) {
      const reply = replyFor(msg.botId, msg.text);
      const steps: Step[] = [{ kind: 'wait', ticks: 3 }, { kind: 'say', text: reply.text }];
      if (reply.handoff) {
        const to = reply.handoff;
        steps.push({
          kind: 'effect',
          run: (st) => withItem(st, 'shion', { role: 'handoff', text: `交给了「${st.bots.find((b) => b.id === to)?.name}」`, at: demoNow(), to }),
        });
      }
      runners.push({ botId: msg.botId, steps, idx: 0, progress: 0 });
    }
    if (Math.random() < 0.03) next = { ...next, connection: { ...next.connection, latencyMs: 14 + Math.round(Math.random() * 12) } };
    return next;
  });
}

export function startSimulator(): () => void {
  const id = window.setInterval(onTick, TICK_MS);
  return () => window.clearInterval(id);
}
