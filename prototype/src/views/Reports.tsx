import { CircleAlert, CircleCheck, CircleHelp } from 'lucide-react';
import type { AppState, ReportKind } from '../data/model';
import { AskCard } from '../components/Items';
import { Toolbar } from '../components/Shell';
import { AREA, Avatar } from '../ui/bits';
import { dayLabel, hm, minutes, useNow } from '../ui/format';

const KINDS: { key: ReportKind; label: string }[] = [
  { key: 'study', label: '学习' },
  { key: 'work', label: '工作' },
  { key: 'life', label: '生活' },
  { key: 'news', label: '新闻' },
];

const CHECK = {
  verified: { label: '已核实', tone: 'good', icon: CircleCheck },
  single: { label: '单一来源', tone: 'warning', icon: CircleHelp },
  disputed: { label: '存疑', tone: 'critical', icon: CircleAlert },
} as const;

export function Reports({ state, kind }: { state: AppState; kind: ReportKind }) {
  const now = useNow(30_000);
  const r = state.reports.find((x) => x.kind === kind);
  const bot = state.bots.find((b) => b.id === r?.botId);
  const total = state.usage.reduce((n, u) => n + u.minutes, 0);
  const maxApp = Math.max(...state.apps.map((a) => a.minutes));

  return (
    <>
      <Toolbar title="日报" sub="由助手按时写好，同时可以推送到手机">
        <div className="segmented" role="group" aria-label="日报类型">
          {KINDS.map((k) => (
            <button key={k.key} aria-pressed={kind === k.key} onClick={() => (location.hash = `reports-${k.key}`)}>
              {k.key !== 'news' && <span className="area-dot" style={{ background: AREA[k.key as 'study'].slot }} />}
              {k.label}
            </button>
          ))}
        </div>
      </Toolbar>
      <div className="view">
        <div className="pad report">
          {r ? (
            <>
              <header className="report-head">
                <span className="eyebrow">
                  {dayLabel(r.date, now)} · {KINDS.find((k) => k.key === kind)?.label}日报
                </span>
                <h2>{r.headline}</h2>
                <span className="by">
                  <Avatar bot={bot} size={18} />
                  「{bot?.name}」{hm(r.date)} 写 · <a href={`#chat-${bot?.id}`}>在对话里追问</a>
                </span>
              </header>

              {kind === 'life' && (
                <section className="report-sec">
                  <h3>屏幕时间 {minutes(total)}</h3>
                  <div className="seg-bar" role="img" aria-label={state.usage.map((u) => `${u.label} ${minutes(u.minutes)}`).join('，')}>
                    {state.usage.map((u) => (
                      <span key={u.label} style={{ flexGrow: u.minutes, background: AREA[u.area].slot }} title={`${u.label} ${minutes(u.minutes)}`} />
                    ))}
                  </div>
                  <div className="seg-legend">
                    {state.usage.map((u) => (
                      <span key={u.label}>
                        <span className="area-dot" style={{ background: AREA[u.area].slot }} />
                        {u.label} <b className="num">{minutes(u.minutes)}</b>
                      </span>
                    ))}
                  </div>
                  <table className="app-table">
                    <caption>按应用（来自这台 Mac 的应用记录）</caption>
                    <tbody>
                      {state.apps.map((a) => (
                        <tr key={a.app}>
                          <th scope="row">{a.app}</th>
                          <td className="bar-cell">
                            <span className="hbar" style={{ width: `${(a.minutes / maxApp) * 100}%`, background: AREA[a.area].slot }} />
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
                    {state.news.map((n) => {
                      const c = CHECK[n.check];
                      const Icon = c.icon;
                      return (
                        <li key={n.title}>
                          <div className="nt">{n.title}</div>
                          <div className="nm">
                            <span className={`pill tone-${c.tone}`}>
                              <Icon size={11} />
                              {c.label}
                            </span>
                            <span className="faint">
                              {n.source} · {n.checkNote}
                            </span>
                          </div>
                        </li>
                      );
                    })}
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
            <div className="empty">还没有这类日报</div>
          )}
        </div>
      </div>
    </>
  );
}

export function Confirm({ state }: { state: AppState }) {
  const now = useNow(10_000);
  return (
    <>
      <Toolbar title="等你确认" sub="助手要发出去、改掉或替你决定的事，都会先停在这里" />
      <div className="view">
        <div className="pad">
          {state.asks.length === 0 ? (
            <div className="panel empty" style={{ maxWidth: 720 }}>
              <CircleCheck size={24} color="var(--good)" />
              <strong>没有等你确认的事</strong>
              <span>发邮件、改日程、替你决定这类事情，助手会先停下来问你；Mac 上也会弹通知，可以直接在通知里回复。</span>
            </div>
          ) : (
            <div className="ask-page">
              {state.asks.map((a) => (
                <AskCard key={a.id} ask={a} state={state} now={now} />
              ))}
            </div>
          )}
        </div>
      </div>
    </>
  );
}
