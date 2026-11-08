import { Plus, X } from 'lucide-react';
import { useState } from 'react';
import { TodoRow } from '../components/Items';
import { Toolbar } from '../components/Shell';
import { dayDiff } from '../data/clock';
import type { AppState, Area, Todo } from '../data/model';
import { addTodo, updateTodo } from '../data/store';
import { AREA, Avatar } from '../ui/bits';
import { until, useNow, when } from '../ui/format';

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

export function Todos({ state }: { state: AppState }) {
  const now = useNow(5000);
  const [filter, setFilter] = useState<Filter>('all');
  const [sel, setSel] = useState<string | null>(null);
  const [showDone, setShowDone] = useState(false);
  const [draft, setDraft] = useState('');
  const list = state.todos.filter((t) => filter === 'all' || t.area === filter);
  const selected = state.todos.find((t) => t.id === sel);
  const open = state.todos.filter((t) => !t.done);
  const overdue = open.filter((t) => group(t, now) === 'overdue').length;
  const today = open.filter((t) => group(t, now) === 'today').length;

  return (
    <>
      <Toolbar title="待办" sub={`今天 ${today} 件${overdue ? ` · 逾期 ${overdue} 件` : ''}`}>
        <div className="seg" role="group" aria-label="按领域筛选">
          {(['all', 'study', 'work', 'life'] as Filter[]).map((f) => (
            <button key={f} aria-pressed={filter === f} onClick={() => setFilter(f)}>
              {f === 'all' ? '全部' : AREA[f].label}
            </button>
          ))}
        </div>
      </Toolbar>
      <div className="view split">
        <div className="split-main">
          <div className="page narrow">
            <form
              className="add-row"
              onSubmit={(e) => {
                e.preventDefault();
                if (!draft.trim()) return;
                setSel(addTodo({ title: draft.trim(), area: filter === 'all' ? 'life' : filter }));
                setDraft('');
              }}
            >
              <Plus size={16} />
              <input id="todo-add" value={draft} onChange={(e) => setDraft(e.target.value)} placeholder="新待办" aria-label="新待办" />
              {draft.trim() && <kbd>↩</kbd>}
            </form>
            {GROUPS.map((g) => {
              const items = list
                .filter((t) => group(t, now) === g.key)
                .sort((a, b) => (a.doAt ?? a.dueAt ?? Infinity) - (b.doAt ?? b.dueAt ?? Infinity));
              if (!items.length) return null;
              const collapsed = g.key === 'done' && !showDone;
              return (
                <section key={g.key} className={`tgroup g-${g.key}`}>
                  <h3>
                    {g.key === 'done' ? (
                      <button className="link-btn" onClick={() => setShowDone((x) => !x)}>
                        {g.label} {items.length} · {showDone ? '收起' : '展开'}
                      </button>
                    ) : (
                      <>
                        {g.label}
                        <span>{items.length}</span>
                      </>
                    )}
                  </h3>
                  {!collapsed && (
                    <div className="list">
                      {items.map((t) => (
                        <TodoRow
                          key={t.id}
                          t={t}
                          now={now}
                          withDay={g.key !== 'today' && g.key !== 'tomorrow'}
                          selected={t.id === sel}
                          onSelect={() => setSel(t.id)}
                        />
                      ))}
                    </div>
                  )}
                </section>
              );
            })}
          </div>
        </div>
        {selected && <TodoInspector t={selected} state={state} now={now} onClose={() => setSel(null)} />}
      </div>
    </>
  );
}

function TodoInspector({ t, state, now, onClose }: { t: Todo; state: AppState; now: number; onClose: () => void }) {
  const fromBot = t.source.kind === 'class' ? 'study' : t.source.kind === 'mail' ? 'mail' : 'shion';
  const bot = state.bots.find((b) => b.id === fromBot);
  return (
    <aside className="insp" aria-label="待办详情">
      <div className="insp-bar">
        <button className="icon-btn" onClick={onClose} aria-label="关闭">
          <X size={16} />
        </button>
      </div>
      <div className="insp-body">
        <input id={`title-${t.id}`} className="insp-title-input" value={t.title} onChange={(e) => updateTodo(t.id, { title: e.target.value })} aria-label="标题" />
        {t.proposed && <p className="insp-note warm">日期是「{bot?.name}」建议的，改好或直接确认都行。</p>}
        <dl className="fields">
          <dt>执行</dt>
          <dd>
            <input id={`do-${t.id}`} type="datetime-local" className="field" value={toLocal(t.doAt)} onChange={(e) => updateTodo(t.id, { doAt: fromLocal(e.target.value) })} />
          </dd>
          <dt>截止</dt>
          <dd>
            <input id={`due-${t.id}`} type="datetime-local" className="field" value={toLocal(t.dueAt)} onChange={(e) => updateTodo(t.id, { dueAt: fromLocal(e.target.value) })} />
            {t.dueAt && !t.done && <span className={t.dueAt < now ? 'red' : 'quiet'}>{until(t.dueAt, now)}</span>}
          </dd>
          <dt>领域</dt>
          <dd>
            <div className="seg sm" role="group" aria-label="领域">
              {(['study', 'work', 'life'] as Area[]).map((a) => (
                <button key={a} aria-pressed={t.area === a} onClick={() => updateTodo(t.id, { area: a })}>
                  {AREA[a].label}
                </button>
              ))}
            </div>
          </dd>
          <dt>来自</dt>
          <dd>
            <a href={`#chat-${fromBot}`} className="inline-link">
              <Avatar bot={bot} size={16} />
              {t.source.label}
            </a>
          </dd>
        </dl>
        <section className="insp-sec">
          <h4>詩音会这样提醒你</h4>
          <ul className="plain">
            {t.doAt && <li>到执行时间（{when(t.doAt, now)}）提醒一次</li>}
            {t.dueAt && <li>截止前 24 小时、3 小时各催一次</li>}
            <li>还没动的话，晚上 21:00 再提一次</li>
            {t.nudges > 0 && <li className="quiet">已经催过 {t.nudges} 次</li>}
          </ul>
        </section>
        <section className="insp-sec">
          <h4>备注</h4>
          <textarea id={`notes-${t.id}`} className="field" rows={4} value={t.notes ?? ''} onChange={(e) => updateTodo(t.id, { notes: e.target.value })} placeholder="写点什么，助手处理这件事时会读到" />
        </section>
      </div>
    </aside>
  );
}
