import { AskCard } from '../components/Items';
import { Toolbar } from '../components/Shell';
import type { AppState, NewsItem, ReportKind } from '../data/model';
import { sortAsks } from '../data/store';
import { AREA, Avatar } from '../ui/bits';
import { dayLabel, hm, md, minutes, useNow, weekday } from '../ui/format';

const KINDS: { key: ReportKind; label: string }[] = [
  { key: 'study', label: '学习' },
  { key: 'work', label: '工作' },
  { key: 'life', label: '生活' },
  { key: 'news', label: '新闻' },
];

const CHECK: Record<NewsItem['check'], { label: string; tone: string }> = {
  verified: { label: '已核实', tone: 'ok' },
  single: { label: '单一来源', tone: 'warm' },
  disputed: { label: '存疑', tone: 'red' },
};

export function Reports({ state, kind }: { state: AppState; kind: ReportKind }) {
  const now = useNow(30_000);
  const r = state.reports.find((x) => x.kind === kind);
  const bot = state.bots.find((b) => b.id === r?.botId);
  const maxApp = Math.max(...state.apps.map((a) => a.minutes));

  return (
    <>
      <Toolbar title="日报">
        <div className="seg" role="group" aria-label="日报类型">
          {KINDS.map((k) => (
            <button key={k.key} aria-pressed={kind === k.key} onClick={() => (location.hash = `reports-${k.key}`)}>
              {k.label}
            </button>
          ))}
        </div>
      </Toolbar>
      <div className="view">
        <article className="page report">
          {r ? (
            <>
              <header className="report-head">
                <p className="eyebrow">
                  {kind !== 'news' && <span className="area-dot" style={{ background: AREA[kind].slot }} />}
                  {KINDS.find((k) => k.key === kind)?.label}日报 · {dayLabel(r.date, now)} {md(r.date)} {weekday(r.date)}
                </p>
                <h2>{r.headline}</h2>
                <p className="byline">
                  <Avatar bot={bot} size={18} />
                  {bot?.name} {hm(r.date)} 写 · 也发到了你的手机 ·
                  <a className="inline-link" href={`#chat-${bot?.id}`}>
                    追问
                  </a>
                </p>
              </header>

              {kind === 'life' && (
                <section className="report-sec">
                  <h3>时间都去了哪</h3>
                  <div className="seg-bar" role="img" aria-label={state.usage.map((u) => `${u.label} ${minutes(u.minutes)}`).join('，')}>
                    {state.usage.map((u) => (
                      <span key={u.label} style={{ flexGrow: u.minutes, background: AREA[u.area].slot }} title={`${u.label} ${minutes(u.minutes)}`} />
                    ))}
                  </div>
                  <div className="seg-legend">
                    {state.usage.map((u) => (
                      <span key={u.label}>
                        <span className="area-dot" style={{ background: AREA[u.area].slot }} />
                        {u.label}
                        <b className="num">{minutes(u.minutes)}</b>
                      </span>
                    ))}
                  </div>
                  <table className="apps">
                    <caption>按应用，来自这台 Mac 的使用记录</caption>
                    <tbody>
                      {state.apps.map((a) => (
                        <tr key={a.app}>
                          <th scope="row">{a.app}</th>
                          <td className="apps-bar">
                            <span style={{ width: `${(a.minutes / maxApp) * 100}%`, background: AREA[a.area].slot }} />
                          </td>
                          <td className="num">{minutes(a.minutes)}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </section>
              )}

              {kind === 'news' && (
                <section className="report-sec">
                  <ol className="news">
                    {state.news.map((n) => (
                      <li key={n.title}>
                        <p className="news-title">{n.title}</p>
                        <p className="news-meta">
                          <span className={`news-check ${CHECK[n.check].tone}`}>{CHECK[n.check].label}</span>
                          {n.source} · {n.checkNote}
                        </p>
                      </li>
                    ))}
                  </ol>
                </section>
              )}

              {r.blocks.map((b) => (
                <section key={b.heading} className="report-sec">
                  <h3>{b.heading}</h3>
                  <ul>
                    {b.lines.map((l) => (
                      <li key={l}>{l}</li>
                    ))}
                  </ul>
                </section>
              ))}
            </>
          ) : (
            <p className="quiet">还没有这类日报。</p>
          )}
        </article>
      </div>
    </>
  );
}

export function Confirm({ state }: { state: AppState }) {
  const now = useNow(10_000);
  const asks = sortAsks(state.asks);
  return (
    <>
      <Toolbar title="等你确认" sub={asks.length ? `${asks.length} 件` : undefined} />
      <div className="view">
        <div className="page confirm">
          {asks.length === 0 ? (
            <div className="empty-state">
              <h2>都处理完了</h2>
              <p>助手要发出去、改掉或替你决定的事，会先停在这里。Mac 上也会弹通知，可以直接在通知里回复。</p>
            </div>
          ) : (
            <>
              <p className="quiet">助手要发出去、改掉或替你决定的事，都会先停在这里，等你点头。</p>
              {asks.map((a) => (
                <AskCard key={a.id} ask={a} state={state} now={now} />
              ))}
            </>
          )}
        </div>
      </div>
    </>
  );
}
