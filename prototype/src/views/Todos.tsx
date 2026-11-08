import { BellRing, CircleCheck, LoaderCircle, Plus, X } from 'lucide-react';
import { useState } from 'react';
import { dayDiff } from '../data/clock';
import type { AppState, Area, Todo } from '../data/model';
import { addTodo, updateTodo } from '../data/store';
import { TodoRow } from '../components/Items';
import { Toolbar } from '../components/Shell';
import { AREA, AreaChip, Avatar } from '../ui/bits';
import { ago, until, useNow, when } from '../ui/format';

type Filter = 'all' | Area;

function group(t: Todo, now: number): string {
  if (t.done) return 'done';
  if ((t.dueAt && t.dueAt < now) || (!t.dueAt && t.doAt && dayDiff(t.doAt, now) < 0)) return 'overdue';
  const key = t.doAt ?? t.dueAt;
  if (key == null) return 'none';
  const d = Math.min(dayDiff(key, now), t.dueAt ? dayDiff(t.dueAt, now) : Infinity);
  if (d <= 0) return 'today';
  if (d === 1) return 'tomorrow';
  if (d < 7) return 'week';
  return 'later';
}

const GROUPS: { key: string; label: string }[] = [
  { key: 'overdue', label: '逾期' },
  { key: 'today', label: '今天' },
  { key: 'tomorrow', label: '明天' },
  { key: 'week', label: '这周' },
  { key: 'later', label: '以后' },
  { key: 'none', label: '没定日期' },
  { key: 'done', label: '已完成' },
];

const toLocal = (t?: number) => {
  if (t == null) return '';
  const d = new Date(t - new Date(t).getTimezoneOffset() * 60000);
  return d.toISOString().slice(0, 16);
};
const fromLocal = (v: string) => (v ? new Date(v).getTime() : undefined);

export function Todos({ state, tab }: { state: AppState; tab: 'mine' | 'delegated' }) {
  const now = useNow(5000);
  const [filter, setFilter] = useState<Filter>('all');
  const [sel, setSel] = useState<string | null>(null);
  const [showDone, setShowDone] = useState(false);
  const [draft, setDraft] = useState('');
  const list = state.todos.filter((t) => filter === 'all' || t.area === filter);
  const selected = state.todos.find((t) => t.id === sel);

  return (
    <>
      <Toolbar title="待办" sub={`${state.todos.filter((t) => !t.done).length} 件未完成 · ${state.todos.filter((t) => t.proposed).length} 件等你确认日期`}>
        <div className="segmented" role="group" aria-label="待办范围">
          <button aria-pressed={tab === 'mine'} onClick={() => (location.hash = 'todos')}>
            我的
          </button>
          <button aria-pressed={tab === 'delegated'} onClick={() => (location.hash = 'todos-delegated')}>
            交给助手的
          </button>
        </div>
        {tab === 'mine' && (
          <div className="segmented hide-narrow" role="group" aria-label="按领域筛选">
            {(['all', 'study', 'work', 'life'] as Filter[]).map((f) => (
              <button key={f} aria-pressed={filter === f} onClick={() => setFilter(f)}>
                {f === 'all' ? '全部' : AREA[f].label}
              </button>
            ))}
          </div>
        )}
      </Toolbar>
      <div className="view" style={{ overflow: 'hidden' }}>
        {tab === 'delegated' ? (
          <Delegated state={state} now={now} />
        ) : (
          <div className="split">
            <div className="split-main">
              <form
                className="quick-add"
                onSubmit={(e) => {
                  e.preventDefault();
                  if (!draft.trim()) return;
                  setSel(addTodo({ title: draft.trim(), area: filter === 'all' ? 'life' : filter }));
                  setDraft('');
                }}
              >
                <Plus size={15} />
                <input id="todo-add" value={draft} onChange={(e) => setDraft(e.target.value)} placeholder="添加待办，回车保存；日期可以之后再定，或者让紫苑帮你排" />
              </form>
              {GROUPS.map((g) => {
                const items = list
                  .filter((t) => group(t, now) === g.key)
                  .sort((a, b) => (a.doAt ?? a.dueAt ?? Infinity) - (b.doAt ?? b.dueAt ?? Infinity));
                if (!items.length) return null;
                const collapsed = g.key === 'done' && !showDone;
                return (
                  <section key={g.key} className={`todo-group g-${g.key}`}>
                    <h3>
                      {g.key === 'done' ? (
                        <button className="linkish" onClick={() => setShowDone((x) => !x)}>
                          {g.label} {items.length} · {showDone ? '收起' : '展开'}
                        </button>
                      ) : (
                        <>
                          {g.label} <span className="faint num">{items.length}</span>
                        </>
                      )}
                    </h3>
                    {!collapsed && (
                      <div className="todo-list">
                        {items.map((t) => (
                          <TodoRow key={t.id} t={t} now={now} selected={t.id === sel} onSelect={() => setSel(t.id)} />
                        ))}
                      </div>
                    )}
                  </section>
                );
              })}
            </div>
            {selected && <TodoInspector t={selected} state={state} now={now} onClose={() => setSel(null)} />}
          </div>
        )}
      </div>
    </>
  );
}

function TodoInspector({ t, state, now, onClose }: { t: Todo; state: AppState; now: number; onClose: () => void }) {
  const fromBot = t.source.kind === 'class' ? 'study' : t.source.kind === 'mail' ? 'mail' : 'shion';
  const bot = state.bots.find((b) => b.id === fromBot);
  return (
    <aside className="inspector" aria-label="待办详情">
      <div className="insp-head">
        <AreaChip area={t.area} />
        {t.proposed && <span className="pill tone-warning">等你确认日期</span>}
        <button className="btn ghost icon" style={{ marginLeft: 'auto' }} onClick={onClose} aria-label="关闭">
          <X size={15} />
        </button>
      </div>
      <div className="insp-body">
        <input id={`title-${t.id}`} className="title-input" value={t.title} onChange={(e) => updateTodo(t.id, { title: e.target.value })} aria-label="标题" />
        <dl className="props">
          <dt>执行日期</dt>
          <dd>
            <input id={`do-${t.id}`} type="datetime-local" className="field" value={toLocal(t.doAt)} onChange={(e) => updateTodo(t.id, { doAt: fromLocal(e.target.value) })} />
          </dd>
          <dt>截止日期</dt>
          <dd>
            <input id={`due-${t.id}`} type="datetime-local" className="field" value={toLocal(t.dueAt)} onChange={(e) => updateTodo(t.id, { dueAt: fromLocal(e.target.value) })} />
            {t.dueAt && !t.done && <span className={`faint${t.dueAt < now ? ' over-text' : ''}`}>{until(t.dueAt, now)}</span>}
          </dd>
          <dt>领域</dt>
          <dd>
            <select id={`area-${t.id}`} className="field" value={t.area} onChange={(e) => updateTodo(t.id, { area: e.target.value as Area })}>
              <option value="study">学习</option>
              <option value="work">工作</option>
              <option value="life">生活</option>
            </select>
          </dd>
          <dt>来源</dt>
          <dd>
            <a href={`#chat-${fromBot}`} className="chip">
              <Avatar bot={bot} size={14} />
              {t.source.label}
            </a>
          </dd>
        </dl>
        <section className="side-sec">
          <h3>紫苑怎么催你</h3>
          <ul className="nudge-plan">
            {t.doAt && <li>到执行时间（{when(t.doAt, now)}）提醒一次</li>}
            {t.dueAt && <li>截止前 24 小时、3 小时各催一次</li>}
            <li>没动静的话，晚上 21:00 的催促里再提一次</li>
            {t.nudges > 0 && (
              <li className="faint">
                <BellRing size={11} /> 已经催过 {t.nudges} 次
              </li>
            )}
          </ul>
        </section>
        <section className="side-sec">
          <h3>备注</h3>
          <textarea id={`notes-${t.id}`} className="field" rows={4} value={t.notes ?? ''} onChange={(e) => updateTodo(t.id, { notes: e.target.value })} placeholder="写点什么，助手处理这件事时会读到" />
        </section>
      </div>
    </aside>
  );
}

function Delegated({ state, now }: { state: AppState; now: number }) {
  const cols = [
    { key: 'running', label: '在做' },
    { key: 'waiting', label: '等你' },
    { key: 'done', label: '做完了' },
  ] as const;
  return (
    <div className="pad">
      <p className="muted" style={{ marginTop: 0, maxWidth: 640 }}>
        你交代给紫苑、再由紫苑分给各个助手的事。背后是 Hermes 的看板，助手之间靠评论交接。
      </p>
      <div className="deleg-cols">
        {cols.map((c) => {
          const items = state.delegations.filter((d) => d.state === c.key);
          return (
            <section key={c.key} className="deleg-col">
              <h3>
                {c.label} <span className="faint num">{items.length}</span>
              </h3>
              {items.map((d) => {
                const b = state.bots.find((x) => x.id === d.botId);
                return (
                  <a key={d.id} className="panel deleg-card" href={`#chat-${d.botId}`}>
                    <div className="dc-top">
                      <Avatar bot={b} size={22} />
                      <span>{b?.name}</span>
                      {c.key === 'running' && <LoaderCircle size={13} className="spin" color="var(--info)" />}
                      {c.key === 'done' && <CircleCheck size={13} color="var(--good)" />}
                      <span className="faint" style={{ marginLeft: 'auto' }}>
                        {ago(d.updatedAt, now)}
                      </span>
                    </div>
                    <div className="dc-title">{d.title}</div>
                    <div className="muted">{d.note}</div>
                  </a>
                );
              })}
              {items.length === 0 && <div className="faint empty-col">没有</div>}
            </section>
          );
        })}
      </div>
    </div>
  );
}
