import { ArrowRight, BookOpen, Briefcase, CircleCheck, Focus, LoaderCircle, Send, TrainFront, TriangleAlert } from 'lucide-react';
import { useState } from 'react';
import { dayDiff } from '../data/clock';
import type { AppState, CalEvent, Todo } from '../data/model';
import { sendMessage, sortAsks } from '../data/store';
import { AskCard, TodoRow } from '../components/Items';
import { Toolbar } from '../components/Shell';
import { go } from '../route';
import { AREA, Avatar } from '../ui/bits';
import { hm, md, until, useNow, weekday } from '../ui/format';

const KIND_ICON = { class: BookOpen, event: Briefcase, commute: TrainFront, focus: Focus };

function brief(state: AppState, now: number) {
  const today = state.events.filter((e) => dayDiff(e.start, now) === 0);
  const nextClass = today.find((e) => e.kind === 'class' && e.start > now);
  const nextEvent = today.find((e) => e.kind === 'event' && e.start > now);
  const open = state.todos.filter((t) => !t.done && ((t.doAt && dayDiff(t.doAt, now) <= 0) || (t.dueAt && dayDiff(t.dueAt, now) <= 0)));
  const due = open.filter((t) => t.dueAt && t.dueAt > now).sort((a, b) => a.dueAt! - b.dueAt!)[0];
  const parts: string[] = [];
  const h = new Date(now).getHours();
  parts.push(h < 12 ? (today.some((e) => e.kind === 'class' && e.end < now) ? '上午的课结束了。' : '早上好。') : h < 18 ? '下午好。' : '晚上好。');
  const later = [nextClass && `${nextClass.title.replace(/ 第\d+回/, '')}（${hm(nextClass.start)}）`, nextEvent && `${nextEvent.title}（${hm(nextEvent.start)}）`].filter(Boolean);
  if (later.length) parts.push(`接下来还有 ${later.join('和 ')}。`);
  parts.push(`今天还剩 ${open.length} 件待办${due ? `，最近的截止是「${due.title}」${hm(due.dueAt!)}（${until(due.dueAt!, now)}）` : ''}。`);
  if (state.asks.length) parts.push(`有 ${state.asks.length} 件事等你确认。`);
  return parts.join('');
}

type PlanRow = { at: number; end?: number; kind: 'event'; e: CalEvent } | { at: number; kind: 'todo'; t: Todo };

export function Today({ state }: { state: AppState }) {
  const now = useNow(1000);
  const [text, setText] = useState('');
  const chief = state.bots.find((b) => b.chief)!;
  const study = state.bots.find((b) => b.id === 'study');
  const events = state.events.filter((e) => dayDiff(e.start, now) === 0);
  const eventTitles = new Set(events.map((e) => e.title));
  const plan: PlanRow[] = [
    ...events.map((e) => ({ at: e.start, end: e.end, kind: 'event' as const, e })),
    ...state.todos
      .filter((t) => t.doAt && dayDiff(t.doAt, now) === 0 && !eventTitles.has(t.title))
      .map((t) => ({ at: t.doAt!, kind: 'todo' as const, t })),
  ].sort((a, b) => a.at - b.at);
  const nowIdx = plan.findIndex((r) => r.at > now);

  const todo = state.todos
    .filter((t) => !t.done && ((t.doAt && dayDiff(t.doAt, now) <= 0) || (t.dueAt && dayDiff(t.dueAt, now) <= 0) || t.proposed))
    .sort((a, b) => (a.dueAt ?? a.doAt ?? Infinity) - (b.dueAt ?? b.doAt ?? Infinity));
  const doneToday = state.todos.filter((t) => t.done && t.doneAt && dayDiff(t.doneAt, now) === 0).length;
  const busy = state.delegations.filter((d) => d.state !== 'done');
  const reports = state.reports;

  const submit = (e: React.FormEvent) => {
    e.preventDefault();
    if (!text.trim()) return;
    sendMessage(chief.id, text.trim());
    setText('');
    go(`chat-${chief.id}`);
  };

  return (
    <>
      <Toolbar title="今天" sub={`${md(now)} ${weekday(now)} · 示例数据`} />
      <div className="view">
        <div className="pad today">
          <section className="brief">
            <div className="brief-date">
              <span className="big num">{md(now)}</span>
              <span className="muted">
                {weekday(now)} · {hm(now)}
              </span>
            </div>
            <div className="brief-line">
              <Avatar bot={chief} size={30} />
              <p>{brief(state, now)}</p>
            </div>
          </section>

          <div className="today-grid">
            <section className="panel">
              <div className="panel-head">
                <h2>今天的安排</h2>
                <a className="btn ghost mini" href="#calendar">
                  看一周
                </a>
              </div>
              <ol className="plan">
                {plan.map((r, i) => {
                  const past = (r.kind === 'event' ? r.end ?? r.at : r.at) < now;
                  const live = r.kind === 'event' && r.at <= now && (r.end ?? r.at) > now;
                  return (
                    <li key={r.kind === 'event' ? r.e.id : r.t.id} className={`${past ? 'past' : ''}${live ? ' live' : ''}`}>
                      {i === nowIdx && (
                        <div className="now-line" aria-label={`现在 ${hm(now)}`}>
                          <span>{hm(now)}</span>
                        </div>
                      )}
                      <div className="plan-row">
                        <time className="num">{hm(r.at)}</time>
                        {r.kind === 'event' ? <EventCard e={r.e} state={state} now={now} studyBusy={study?.status === 'working'} /> : <PlanTodo t={r.t} />}
                      </div>
                    </li>
                  );
                })}
                {nowIdx === -1 && (
                  <li>
                    <div className="now-line">
                      <span>{hm(now)}</span>
                    </div>
                  </li>
                )}
              </ol>
            </section>

            <div className="stack">
              {state.asks.length > 0 && (
                <section className="panel">
                  <div className="panel-head">
                    <h2>等你确认</h2>
                    <a className="btn ghost mini" href="#confirm">
                      全部 {state.asks.length}
                    </a>
                  </div>
                  <div className="ask-list">
                    {sortAsks(state.asks).slice(0, 3).map((a) => (
                      <AskCard key={a.id} ask={a} state={state} now={now} compact />
                    ))}
                  </div>
                </section>
              )}

              <section className="panel">
                <div className="panel-head">
                  <h2>要做的事</h2>
                  <span className="faint num">已完成 {doneToday}</span>
                  <a className="btn ghost mini" href="#todos">
                    全部
                  </a>
                </div>
                <div className="todo-list">
                  {todo.slice(0, 7).map((t) => (
                    <TodoRow key={t.id} t={t} now={now} onSelect={() => go('todos')} />
                  ))}
                  {todo.length === 0 && (
                    <div className="empty">
                      <CircleCheck size={20} color="var(--good)" />
                      <strong>今天的都做完了</strong>
                    </div>
                  )}
                </div>
              </section>

              <section className="panel">
                <div className="panel-head">
                  <h2>日报</h2>
                  <a className="btn ghost mini" href="#reports">
                    全部
                  </a>
                </div>
                <div className="report-tiles">
                  {(['news', 'study', 'work', 'life'] as const).map((k) => {
                    const r = reports.find((x) => x.kind === k);
                    if (!r) return null;
                    return (
                      <a key={k} className="report-tile" href={`#reports-${k}`}>
                        <span className="rk">
                          {k !== 'news' && <span className="area-dot" style={{ background: AREA[k].slot }} />}
                          {{ news: '新闻 · 今天 07:00', study: '学习 · 昨天', work: '工作 · 昨天', life: '生活 · 昨天' }[k]}
                        </span>
                        <span className="rh">{r.headline}</span>
                      </a>
                    );
                  })}
                </div>
              </section>

              {busy.length > 0 && (
                <section className="panel">
                  <div className="panel-head">
                    <h2>助手在做</h2>
                    <a className="btn ghost mini" href="#todos-delegated">
                      全部
                    </a>
                  </div>
                  <ul className="deleg-list">
                    {busy.map((d) => {
                      const b = state.bots.find((x) => x.id === d.botId);
                      return (
                        <li key={d.id}>
                          <a href={`#chat-${d.botId}`}>
                            <Avatar bot={b} size={22} />
                            <span className="dl-main">
                              <span>{d.title}</span>
                              <span className="faint">
                                {b?.name} · {d.note}
                              </span>
                            </span>
                            {d.state === 'running' ? <LoaderCircle size={14} className="spin" color="var(--info)" /> : <span className="pill tone-warning">等你</span>}
                          </a>
                        </li>
                      );
                    })}
                  </ul>
                </section>
              )}
            </div>
          </div>
        </div>
      </div>
      <form className="ask-bar" onSubmit={submit}>
        <Avatar bot={chief} size={24} />
        <input id="today-ask" className="field" value={text} onChange={(e) => setText(e.target.value)} placeholder="跟紫苑说：「把实验报告挪到明天」「明天几点出门？」" />
        <button className="btn primary" type="submit" disabled={!text.trim()}>
          <Send size={13} />
          发送
        </button>
      </form>
    </>
  );
}

function EventCard({ e, state, now, studyBusy }: { e: CalEvent; state: AppState; now: number; studyBusy: boolean }) {
  const Icon = KIND_ICON[e.kind];
  const proposed = state.todos.filter((t) => t.source.label === e.title && t.proposed).length;
  const fromClass = state.todos.filter((t) => t.source.label === e.title).length;
  const isReturn = e.kind === 'commute' && e.start > now;
  return (
    <div className={`plan-card kind-${e.kind}`} style={{ ['--c' as string]: AREA[e.area].slot }}>
      <div className="pc-top">
        <Icon size={14} />
        <span className="pc-title">{e.title}</span>
        <span className="faint num">
          {hm(e.start)}–{hm(e.end)}
        </span>
      </div>
      {(e.place || e.note) && <div className="pc-sub">{[e.place, e.note].filter(Boolean).join(' · ')}</div>}
      {e.kind === 'class' && e.end < now && (
        <div className="pc-extra">
          {studyBusy && fromClass === 0 ? (
            <>
              <LoaderCircle size={12} className="spin" color="var(--info)" /> 「课程」正在整理录音
            </>
          ) : fromClass > 0 ? (
            <a href="#todos">
              课后整理出 {fromClass} 件事{proposed ? `，${proposed} 件等你确认日期` : ''} <ArrowRight size={11} />
            </a>
          ) : null}
        </div>
      )}
      {e.kind === 'class' && e.start > now && e.start - now < 3 * 3_600_000 && <div className="pc-extra faint">课前 10 分钟提醒你</div>}
      {isReturn && (
        <div className="pc-extra">
          {state.commute.status === 'normal' ? (
            <span className="pill tone-good">{state.commute.statusNote}</span>
          ) : (
            <span className="pill tone-warning">
              <TriangleAlert size={11} />
              {state.commute.statusNote}
            </span>
          )}
          <span className="faint">{state.commute.route.join(' → ')}</span>
        </div>
      )}
    </div>
  );
}

function PlanTodo({ t }: { t: Todo }) {
  return (
    <div className={`plan-card kind-todo${t.done ? ' done' : ''}`} style={{ ['--c' as string]: AREA[t.area].slot }}>
      <div className="pc-top">
        <CircleCheck size={14} />
        <span className="pc-title">{t.title}</span>
        <span className="faint">待办</span>
      </div>
    </div>
  );
}
