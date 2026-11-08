import { CircleAlert, CircleCheck, Coins, Inbox, KeyRound, LoaderCircle, OctagonAlert, ShieldAlert, CircleHelp } from 'lucide-react';
import type { AppState } from '../data/model';
import { Toolbar } from '../components/Shell';
import { taskHref } from '../route';
import { Avatar, BotStatusPill, toneVar } from '../ui/bits';
import { ago, compact, usd, useNow } from '../ui/format';

export function Overview({ state }: { state: AppState }) {
  const now = useNow();
  const online = state.bots.filter((b) => b.status !== 'offline').length;
  const running = state.tasks.filter((t) => t.status === 'running');
  const blocked = state.tasks.filter((t) => t.status === 'blocked');
  const tokens = state.bots.reduce((n, b) => n + b.tokensToday, 0);
  const cost = state.bots.reduce((n, b) => n + b.costToday, 0);
  const botOf = (id?: string | null) => state.bots.find((b) => b.id === id);

  return (
    <>
      <Toolbar title="总览" sub={`${state.bots.length} 个 Bot · ${state.boards.length} 块看板 · 示例数据`} />
      <div className="view">
        <div className="pad">
          <div className="tiles">
            <a className="panel tile" href="#bots">
              <span className="label">在线 Bot</span>
              <span className="value">
                {online}
                <small>/{state.bots.length}</small>
              </span>
              <span className="delta">{state.bots.filter((b) => b.status === 'working').length} 个正在工作</span>
            </a>
            <a className="panel tile" href="#board-default">
              <span className="label">
                <LoaderCircle size={12} color="var(--info)" className="spin" />
                运行中任务
              </span>
              <span className="value">{running.length}</span>
              <span className="delta">分布在 {new Set(running.map((t) => t.assignee)).size} 个 Bot</span>
            </a>
            <a className="panel tile" href="#board-default">
              <span className="label">
                <OctagonAlert size={12} color="var(--crit)" />
                阻塞
              </span>
              <span className="value">{blocked.length}</span>
              <span className="delta">{blocked.filter((t) => t.block?.kind === 'needs_input').length} 个需要人来处理</span>
            </a>
            <a className="panel tile" href="#inbox">
              <span className="label">
                <Inbox size={12} color="var(--warn)" />
                待你处理
              </span>
              <span className="value">{state.inbox.length}</span>
              <span className="delta">审批、提问、密钥</span>
            </a>
            <div className="panel tile">
              <span className="label">
                <Coins size={12} />
                今日用量
              </span>
              <span className="value">{compact(tokens)}</span>
              <span className="delta num">tokens · 约 {usd(cost)}</span>
            </div>
          </div>

          <div className="overview-grid">
            <div className="stack">
              <section className="panel">
                <div className="panel-head">
                  <h2>Bots</h2>
                  <a className="btn ghost" href="#bots">
                    全部
                  </a>
                </div>
                {state.bots.map((b) => (
                  <a key={b.id} className="bot-row" href={`#bot-${b.id}`}>
                    <Avatar bot={b} size={30} />
                    <div style={{ minWidth: 0 }}>
                      <div className="name">
                        {b.displayName}
                        <BotStatusPill status={b.status} />
                      </div>
                      <div className="line">{b.statusNote}</div>
                    </div>
                    <div className="right">
                      <span className="num">{compact(b.tokensToday)} tok</span>
                      <span>{ago(b.lastActiveAt, now)}</span>
                    </div>
                  </a>
                ))}
              </section>

              <section className="panel">
                <div className="panel-head">
                  <h2>实时动态</h2>
                  <span className="pill tone-good">
                    <span className="dot good pulse" />
                    live
                  </span>
                </div>
                <ul className="feed">
                  {state.activity.slice(0, 14).map((a) => (
                    <li key={a.id}>
                      <span className="ic">
                        {a.tone === 'good' ? (
                          <CircleCheck size={14} color="var(--good)" />
                        ) : a.tone === 'neutral' ? (
                          <span className="dot" style={{ display: 'block', margin: '3px' }} />
                        ) : (
                          <CircleAlert size={14} color={`var(--${toneVar(a.tone)})`} />
                        )}
                      </span>
                      <span style={{ minWidth: 0, overflowWrap: 'anywhere' }}>{a.taskId ? <a href={taskHref(a.taskId)}>{a.text}</a> : a.text}</span>
                      <time>{ago(a.at, now)}</time>
                    </li>
                  ))}
                </ul>
              </section>
            </div>

            <section className="panel">
              <div className="panel-head">
                <h2>需要你关注</h2>
                <span className="faint num">{state.inbox.length + blocked.length}</span>
              </div>
              {state.inbox.length + blocked.length === 0 && (
                <div className="empty">
                  <CircleCheck size={22} color="var(--good)" />
                  <strong>都处理完了</strong>
                  <span>新的审批和阻塞会出现在这里</span>
                </div>
              )}
              {state.inbox.map((r) => {
                const b = botOf(r.botId);
                const Icon = r.method === 'approval' ? ShieldAlert : r.method === 'clarify' ? CircleHelp : KeyRound;
                return (
                  <a key={r.rpcId} className="attn" href="#inbox">
                    <Icon size={16} color={r.method === 'approval' ? 'var(--warn)' : 'var(--info)'} style={{ marginTop: 2 }} />
                    <div style={{ minWidth: 0 }}>
                      <div className="t">
                        {b?.displayName}{' '}
                        {r.method === 'approval' ? '请求批准命令' : r.method === 'clarify' ? '向你提问' : `需要 ${r.secret?.name}`}
                      </div>
                      <div className="d">
                        {r.method === 'approval' ? <span className="mono">{r.approval?.command}</span> : r.method === 'clarify' ? r.clarify?.question : r.secret?.prompt}
                      </div>
                      <div className="d faint">{ago(r.at, now)}</div>
                    </div>
                  </a>
                );
              })}
              {blocked.map((t) => (
                <a key={t.id} className="attn" href={taskHref(t.id)}>
                  <OctagonAlert size={16} color="var(--crit)" style={{ marginTop: 2 }} />
                  <div style={{ minWidth: 0 }}>
                    <div className="t">
                      {t.title} <span className="mono faint">{t.id}</span>
                    </div>
                    <div className="d">{t.block?.reason}</div>
                    <div className="d faint">
                      {botOf(t.assignee)?.displayName ?? '未分配'} · {t.block?.kind ?? 'blocked'} · {ago(t.updatedAt, now)}
                    </div>
                  </div>
                </a>
              ))}
            </section>
          </div>
        </div>
      </div>
    </>
  );
}
