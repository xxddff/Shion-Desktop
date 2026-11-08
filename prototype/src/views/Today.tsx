import { ArrowUpRight, Flower2 } from 'lucide-react';
import { useState } from 'react';
import { CardRow } from '../components/Cards';
import { AskRow, TodoRow } from '../components/Items';
import { Toolbar } from '../components/Shell';
import { dayDiff } from '../data/clock';
import type { AppState, CalEvent, Todo } from '../data/model';
import { sendMessage, sortAsks } from '../data/store';
import { go } from '../route';
import { AREA, Busy } from '../ui/bits';
import { hm, md, useNow, weekday } from '../ui/format';

/** What 紫苑 would say if you glanced up right now. */
function brief(state: AppState, now: number) {
  const today = state.events.filter((e) => dayDiff(e.start, now) === 0);
  const nextClass = today.find((e) => e.kind === 'class' && e.start > now);
  const nextEvent = today.find((e) => e.kind === 'event' && e.start > now);
  const open = state.todos.filter((t) => !t.done && ((t.doAt && dayDiff(t.doAt, now) <= 0) || (t.dueAt && dayDiff(t.dueAt, now) <= 0)));
  const due = open.filter((t) => t.dueAt && t.dueAt > now).sort((a, b) => a.dueAt! - b.dueAt!)[0];
  const h = new Date(now).getHours();
  const parts: string[] = [];
  parts.push(h < 12 ? (today.some((e) => e.kind === 'class' && e.end < now) ? '上午的课结束了。' : '早上好。') : h < 18 ? '下午好。' : '晚上好。');
  const later = [nextClass && `${nextClass.title.replace(/ 第\d+回/, '')}（${hm(nextClass.start)}）`, nextEvent && `${nextEvent.title}（${hm(nextEvent.start)}）`].filter(Boolean);
  if (later.length) parts.push(`接下来是${later.join('和')}。`);
  parts.push(`还有 ${open.length} 件待办${due ? `，最先要交的是「${due.title}」，${hm(due.dueAt!)} 截止` : ''}。`);
  return parts.join('');
}

type Row = { at: number; key: string } & ({ kind: 'event'; e: CalEvent } | { kind: 'todo'; t: Todo });

export function Today({ state }: { state: AppState }) {
  const now = useNow(1000);
  const [text, setText] = useState('');
  const chief = state.bots.find((b) => b.chief)!;
  const events = state.events.filter((e) => dayDiff(e.start, now) === 0);
  const titles = new Set(events.map((e) => e.title));
  const agenda: Row[] = [
    ...events.map((e) => ({ at: e.start, key: e.id, kind: 'event' as const, e })),
    ...state.todos
      .filter((t) => t.doAt && dayDiff(t.doAt, now) === 0 && !titles.has(t.title))
      .map((t) => ({ at: t.doAt!, key: t.id, kind: 'todo' as const, t })),
  ].sort((a, b) => a.at - b.at);
  const nowAt = agenda.findIndex((r) => r.at > now);

  const asks = sortAsks(state.asks);
  const todos = state.todos
    .filter((t) => !t.done && !t.proposed && ((t.doAt && dayDiff(t.doAt, now) <= 0) || (t.dueAt && dayDiff(t.dueAt, now) <= 0)))
    .sort((a, b) => (a.dueAt ?? a.doAt ?? Infinity) - (b.dueAt ?? b.doAt ?? Infinity));
  const working = state.cards.filter((c) => c.status === 'running' || c.status === 'blocked' || c.status === 'review');

  const submit = (e: React.FormEvent) => {
    e.preventDefault();
    if (!text.trim()) return;
    sendMessage(chief.id, text.trim());
    setText('');
    go(`chat-${chief.id}`);
  };

  return (
    <>
      <Toolbar title="今天" ask={false} hideTitle />
      <div className="view">
        <div className="page today">
          <header className="hero">
            <h2 className="hero-date">
              {md(now)}
              <span>{weekday(now)}</span>
            </h2>
            <p className="hero-brief">{brief(state, now)}</p>
            <form className="hero-ask" onSubmit={submit}>
              <Flower2 size={16} />
              <input id="today-ask" value={text} onChange={(e) => setText(e.target.value)} placeholder="跟紫苑说：「把实验报告挪到明天」" aria-label="跟紫苑说" />
              {text.trim() && <kbd>↩</kbd>}
            </form>
          </header>

          {asks.length > 0 && (
            <section className="sec">
              <h3 className="sec-title">
                需要你<span className="sec-badge">{asks.length}</span>
                <a className="sec-link" href="#confirm">
                  全部
                </a>
              </h3>
              <ul className="tray">
                {asks.slice(0, 4).map((a) => (
                  <AskRow key={a.id} ask={a} state={state} now={now} />
                ))}
              </ul>
            </section>
          )}

          <div className="today-cols">
            <section className="sec">
              <h3 className="sec-title">
                日程
                <a className="sec-link" href="#calendar">
                  看一周
                </a>
              </h3>
              <ol className="agenda">
                {agenda.map((r, i) => (
                  <AgendaItem key={r.key} row={r} state={state} now={now} showNow={i === nowAt} />
                ))}
                {nowAt === -1 && <NowLine now={now} />}
              </ol>
            </section>

            <div className="today-side">
              <section className="sec">
                <h3 className="sec-title">
                  待办<span className="sec-count">{todos.length}</span>
                  <a className="sec-link" href="#todos">
                    全部
                  </a>
                </h3>
                <div className="list">
                  {todos.map((t) => (
                    <TodoRow key={t.id} t={t} now={now} withDay={dayDiff(t.doAt ?? now, now) !== 0} onSelect={() => go('todos')} />
                  ))}
                  {todos.length === 0 && <p className="empty-line">今天的都做完了。</p>}
                </div>
              </section>

              {working.length > 0 && (
                <section className="sec">
                  <h3 className="sec-title">
                    助手在做
                    <a className="sec-link" href="#board">
                      看板
                    </a>
                  </h3>
                  <div className="list">
                    {working.map((c) => (
                      <CardRow key={c.id} card={c} state={state} now={now} />
                    ))}
                  </div>
                </section>
              )}

              <section className="sec">
                <h3 className="sec-title">日报</h3>
                <div className="list">
                  {(['news', 'study', 'work', 'life'] as const).map((k) => {
                    const r = state.reports.find((x) => x.kind === k);
                    if (!r) return null;
                    return (
                      <a key={k} className="row" href={`#reports-${k}`}>
                        <span className="report-mark" style={{ background: k === 'news' ? 'var(--text-3)' : AREA[k].slot }} />
                        <span className="row-main">
                          <span className="row-title">{{ news: '新闻', study: '学习', work: '工作', life: '生活' }[k]}日报</span>
                          <span className="row-sub">{r.headline}</span>
                        </span>
                        <span className="row-trail">{k === 'news' ? '今天' : '昨天'}</span>
                      </a>
                    );
                  })}
                </div>
              </section>
            </div>
          </div>
        </div>
      </div>
    </>
  );
}

function NowLine({ now }: { now: number }) {
  return (
    <li className="now-line" aria-label={`现在 ${hm(now)}`}>
      <time>{hm(now)}</time>
      <span />
    </li>
  );
}

function AgendaItem({ row, state, now, showNow }: { row: Row; state: AppState; now: number; showNow: boolean }) {
  if (row.kind === 'todo') {
    const t = row.t;
    return (
      <>
        {showNow && <NowLine now={now} />}
        <li className={`ag ag-todo${t.done ? ' past' : ''}`}>
          <time>{hm(row.at)}</time>
          <span className="ag-ring" style={{ borderColor: AREA[t.area].slot }} />
          <span className="ag-main">
            <span className="ag-title">{t.title}</span>
            <span className="ag-sub">待办</span>
          </span>
        </li>
      </>
    );
  }
  const e = row.e;
  const past = e.end < now;
  const live = e.start <= now && e.end > now;
  const fromClass = state.todos.filter((t) => t.source.label === e.title);
  const study = state.bots.find((b) => b.id === 'study');
  let sub: React.ReactNode = [e.place, e.note].filter(Boolean).join(' · ');
  if (e.kind === 'class' && past) {
    sub =
      fromClass.length > 0 ? (
        <a className="ag-link" href="#todos">
          课后整理出 {fromClass.length} 件事 <ArrowUpRight size={11} />
        </a>
      ) : study?.status === 'working' ? (
        <span className="ag-busy">
          <Busy />「课程」在整理录音
        </span>
      ) : (
        sub
      );
  } else if (e.kind === 'class' && e.start - now < 3 * 3_600_000) {
    sub = `${sub} · 课前 10 分钟提醒你`;
  } else if (e.kind === 'commute' && e.start > now) {
    const c = state.commute;
    sub = (
      <>
        {c.route.join(' → ')} · <span className={c.status === 'normal' ? 'ok' : 'warm'}>{c.status === 'normal' ? '运行正常' : c.statusNote}</span>
      </>
    );
  }
  return (
    <>
      {showNow && <NowLine now={now} />}
      <li className={`ag${past ? ' past' : ''}${live ? ' live' : ''}${e.kind === 'commute' || e.kind === 'focus' ? ' soft' : ''}`}>
        <time>{hm(e.start)}</time>
        <span className="ag-bar" style={{ background: AREA[e.area].slot }} />
        <span className="ag-main">
          <span className="ag-title">{e.title}</span>
          {sub && <span className="ag-sub">{sub}</span>}
        </span>
        <span className="ag-end">{hm(e.end)}</span>
      </li>
    </>
  );
}
