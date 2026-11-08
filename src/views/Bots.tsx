import {
  ArrowUpRight,
  CircleAlert,
  CircleCheck,
  FolderGit2,
  HeartPulse,
  LoaderCircle,
  PanelBottom,
  Pause,
  Send,
  ShieldAlert,
} from 'lucide-react';
import { useEffect, useRef, useState } from 'react';
import { Toolbar } from '../components/Shell';
import type { AppState, Bot, Session, TranscriptItem } from '../data/model';
import { interruptSession, steerSession } from '../data/store';
import { taskHref } from '../route';
import { Avatar, BotStatusPill, PlatformChip, PLATFORM, TaskStatusPill } from '../ui/bits';
import { RequestCard } from './Inbox';
import { ago, clock, compact, span, usd, useNow } from '../ui/format';

// ----------------------------------------------------------------- grid

export function BotsGrid({ state }: { state: AppState }) {
  const now = useNow();
  return (
    <>
      <Toolbar title="全部 Bots" sub="每个 Bot 对应一个 Hermes profile，以及它接入的平台" />
      <div className="view">
        <div className="pad">
          <div className="bot-grid">
            {state.bots.map((b) => (
              <BotCard key={b.id} bot={b} state={state} now={now} />
            ))}
          </div>
        </div>
      </div>
    </>
  );
}

function BotCard({ bot, state, now }: { bot: Bot; state: AppState; now: number }) {
  const pending = state.inbox.filter((r) => r.botId === bot.id).length;
  const running = state.tasks.filter((t) => t.assignee === bot.id && t.status === 'running').length;
  return (
    <a className="panel bot-card" href={`#bot-${bot.id}`}>
      <div className="top">
        <Avatar bot={bot} size={38} />
        <div className="who">
          <div>{bot.displayName}</div>
          <div className="faint" style={{ fontSize: 12 }}>
            {bot.role}
          </div>
        </div>
        <BotStatusPill status={bot.status} />
      </div>
      <div className="now">
        {pending > 0 ? <ShieldAlert size={13} color="var(--warn)" /> : <LoaderCircle size={13} className={bot.status === 'working' ? 'spin' : undefined} />}
        <span>{bot.statusNote}</span>
      </div>
      <dl className="kv">
        <div>
          <dt>运行中任务</dt>
          <dd>{running}</dd>
        </div>
        <div>
          <dt>今日 tokens</dt>
          <dd>{compact(bot.tokensToday)}</dd>
        </div>
        <div>
          <dt>最后活动</dt>
          <dd>{ago(bot.lastActiveAt, now)}</dd>
        </div>
      </dl>
      <div className="chips">
        <span className="chip mono">{bot.model}</span>
        {bot.platforms.map((p) => (
          <PlatformChip key={p.kind} kind={p.kind} connected={p.connected} />
        ))}
      </div>
    </a>
  );
}

// ----------------------------------------------------------------- detail

export function BotDetail({ state, botId }: { state: AppState; botId: string }) {
  const now = useNow();
  const bot = state.bots.find((b) => b.id === botId);
  const [sessionId, setSessionId] = useState<string | undefined>(bot?.liveSessionId ?? bot?.sessionIds[0]);
  const [showFrames, setShowFrames] = useState(false);
  useEffect(() => setSessionId(bot?.liveSessionId ?? bot?.sessionIds[0]), [botId]);

  if (!bot) {
    return (
      <>
        <Toolbar title="找不到这个 Bot" />
        <div className="view empty">
          <strong>没有 id 为「{botId}」的 profile</strong>
          <a href="#bots">返回全部 Bots</a>
        </div>
      </>
    );
  }
  const session = sessionId ? state.sessions[sessionId] : undefined;
  const tasks = state.tasks.filter((t) => t.assignee === bot.id && t.status !== 'done' && t.status !== 'archived');
  const pending = state.inbox.filter((r) => r.botId === bot.id);

  return (
    <>
      <Toolbar title={bot.displayName} sub={`profile: ${bot.id} · ${bot.model} · ${bot.provider}`}>
        <button className={`btn ${showFrames ? 'primary' : ''} hide-narrow`} onClick={() => setShowFrames((x) => !x)} aria-pressed={showFrames}>
          <PanelBottom size={13} />
          协议帧
        </button>
      </Toolbar>
      <div className="view" style={{ overflow: 'hidden' }}>
        <div className="bot-detail">
          <div className="bot-main">
            <div className="bot-hero">
              <Avatar bot={bot} size={46} />
              <div className="who">
                <h2>
                  {bot.displayName} <BotStatusPill status={bot.status} />
                </h2>
                <div className="muted">{bot.statusNote}</div>
              </div>
              <dl className="kv" style={{ minWidth: 260 }}>
                <div>
                  <dt>今日 tokens</dt>
                  <dd>{compact(bot.tokensToday)}</dd>
                </div>
                <div>
                  <dt>今日花费</dt>
                  <dd>{usd(bot.costToday)}</dd>
                </div>
                <div>
                  <dt>运行时长</dt>
                  <dd>{span(now - bot.startedAt)}</dd>
                </div>
              </dl>
            </div>
            {pending.length > 0 && (
              <a
                href="#inbox"
                className="pill tone-warning"
                style={{ margin: '0 20px 10px', height: 28, borderRadius: 7, textDecoration: 'none', justifyContent: 'flex-start', padding: '0 10px' }}
              >
                <ShieldAlert size={13} /> {bot.displayName} 有 {pending.length} 个请求在等你处理 <ArrowUpRight size={12} />
              </a>
            )}
            <div className="session-tabs" role="tablist">
              {bot.sessionIds.map((id) => {
                const s = state.sessions[id];
                return (
                  <button key={id} role="tab" aria-selected={id === sessionId} onClick={() => setSessionId(id)}>
                    {s.live && <span className="dot info pulse" />}
                    {s.title}
                  </button>
                );
              })}
            </div>
            {session ? <Transcript session={session} bot={bot} now={now} state={state} /> : <div className="empty">这个 Bot 还没有会话</div>}
            {session && <Composer session={session} bot={bot} />}
            {showFrames && <FramesPanel state={state} sessionId={session?.id} onClose={() => setShowFrames(false)} />}
          </div>

          <aside className="bot-side">
            <section className="side-sec">
              <h3>手上的任务</h3>
              {tasks.length === 0 && <span className="faint">没有进行中的任务</span>}
              {tasks.map((t) => (
                <a key={t.id} className="mini-task" href={taskHref(t.id)}>
                  <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                    <TaskStatusPill status={t.status} />
                    <span className="mono faint">{t.id}</span>
                  </div>
                  <div style={{ fontWeight: 560 }}>{t.title}</div>
                  {t.status === 'running' && t.lastHeartbeatAt && (
                    <div className="faint" style={{ fontSize: 11.5, display: 'flex', gap: 4, alignItems: 'center' }}>
                      <HeartPulse size={11} /> {ago(t.lastHeartbeatAt, now)} · {t.heartbeatNote}
                    </div>
                  )}
                  {t.status === 'blocked' && <div style={{ fontSize: 11.5, color: 'var(--crit)' }}>{t.block?.reason}</div>}
                </a>
              ))}
            </section>
            <section className="side-sec">
              <h3>接入平台</h3>
              {bot.platforms.map((p) => {
                const P = PLATFORM[p.kind];
                return (
                  <div key={p.kind} className="plat">
                    <P.icon size={14} />
                    {P.label}
                    <span className={`dot ${p.connected ? 'good' : 'critical'}`} title={p.connected ? '已连接' : '未连接'} />
                    <span className="h">{p.handle}</span>
                  </div>
                );
              })}
            </section>
            <section className="side-sec">
              <h3>Profile</h3>
              <div className="plat">
                <FolderGit2 size={14} />
                <span className="mono" style={{ fontSize: 11.5 }}>
                  ~/.hermes/profiles/{bot.id}/
                </span>
              </div>
              <div className="muted" style={{ fontSize: 12 }}>
                {bot.role}
              </div>
            </section>
          </aside>
        </div>
      </div>
    </>
  );
}

function Transcript({ session, bot, now, state }: { session: Session; bot: Bot; now: number; state: AppState }) {
  const ref = useRef<HTMLDivElement>(null);
  const stick = useRef(true);
  const last = session.items[session.items.length - 1];
  const pending = state.inbox.filter((r) => r.sessionId === session.id);
  useEffect(() => {
    const el = ref.current;
    if (el && stick.current) el.scrollTop = el.scrollHeight;
  }, [session.id, session.items.length, last?.text, pending.length]);
  return (
    <div
      className="transcript"
      ref={ref}
      onScroll={(e) => {
        const el = e.currentTarget;
        stick.current = el.scrollHeight - el.scrollTop - el.clientHeight < 40;
      }}
    >
      <div className="sysline">
        {session.source} · 开始于 {ago(session.startedAt, now)} · {compact(session.tokens)} tokens
      </div>
      {session.items.map((it) => (
        <Item key={it.id} it={it} bot={bot} />
      ))}
      {pending.map((r) => (
        <RequestCard key={r.rpcId} req={r} state={state} now={now} inline />
      ))}
    </div>
  );
}

function Item({ it, bot }: { it: TranscriptItem; bot: Bot }) {
  if (it.role === 'system') return <div className="sysline">{it.text}</div>;
  if (it.role === 'tool' && it.tool) {
    const t = it.tool;
    const icon =
      t.status === 'running' ? (
        <LoaderCircle size={13} className="spin" color="var(--info)" />
      ) : t.status === 'awaiting' ? (
        <ShieldAlert size={13} color="var(--warn)" />
      ) : t.status === 'error' ? (
        <CircleAlert size={13} color="var(--crit)" />
      ) : (
        <CircleCheck size={13} color="var(--good)" />
      );
    return (
      <div className={`toolcall ${t.status}`}>
        <div className="row">
          {icon}
          <span className="name">{t.name}</span>
          <span className="args">{t.args}</span>
          <span className="faint num" style={{ fontSize: 11 }}>
            {t.status === 'awaiting' ? '等你批准' : t.status === 'running' ? '运行中' : t.durationMs != null ? `${(t.durationMs / 1000).toFixed(1)}s` : ''}
          </span>
        </div>
        {t.output && <div className="out">{t.output}</div>}
      </div>
    );
  }
  const user = it.role === 'user';
  return (
    <div className={`msg ${user ? 'user' : ''}`}>
      <div className="who">
        <span>{user ? (it.author === 'you' ? '你' : it.author ?? '用户') : bot.displayName}</span>
        <span>{clock(it.at)}</span>
      </div>
      <div className="bubble">
        {it.text}
        {it.streaming && <span className="caret" />}
      </div>
    </div>
  );
}

function Composer({ session, bot }: { session: Session; bot: Bot }) {
  const [text, setText] = useState('');
  const streaming = session.items.some((i) => i.streaming || i.tool?.status === 'running');
  const send = (mode: 'steer' | 'background') => {
    if (!text.trim()) return;
    steerSession(session.id, text.trim(), mode);
    setText('');
  };
  return (
    <form
      className="composer"
      onSubmit={(e) => {
        e.preventDefault();
        send('steer');
      }}
    >
      <input
        id={`composer-${session.id}`}
        className="field"
        value={text}
        onChange={(e) => setText(e.target.value)}
        placeholder={session.live ? `给 ${bot.displayName} 一句引导，不打断当前回合…` : '这个会话已结束，消息会作为新一轮提交'}
      />
      <button className="btn primary" type="submit" disabled={!text.trim()} title="session.steer">
        <Send size={13} />
        引导
      </button>
      <button className="btn" type="button" disabled={!text.trim()} onClick={() => send('background')} title="prompt.background">
        后台提交
      </button>
      <button className="btn danger" type="button" disabled={!streaming} onClick={() => interruptSession(session.id)} title="session.interrupt">
        <Pause size={13} />
        打断
      </button>
    </form>
  );
}

function FramesPanel({ state, sessionId, onClose }: { state: AppState; sessionId?: string; onClose: () => void }) {
  const [onlyThis, setOnlyThis] = useState(true);
  const ref = useRef<HTMLDivElement>(null);
  const frames = state.frames.filter((f) => {
    if (!onlyThis || !sessionId) return true;
    const p = f.payload as { session_id?: string } | null;
    return f.channel === 'kanban' || !p?.session_id || p.session_id === sessionId;
  });
  useEffect(() => {
    if (ref.current) ref.current.scrollTop = ref.current.scrollHeight;
  }, [frames.length]);
  return (
    <section className="frames" aria-label="协议帧">
      <div className="frames-head">
        <strong>协议帧</strong>
        <span className="faint">hermes-gateway-v1 · kanban /events</span>
        <label style={{ marginLeft: 'auto', display: 'flex', gap: 4, alignItems: 'center' }} htmlFor="frames-only">
          <input id="frames-only" type="checkbox" checked={onlyThis} onChange={(e) => setOnlyThis(e.target.checked)} />
          只看当前会话
        </label>
        <button className="btn ghost" onClick={onClose}>
          收起
        </button>
      </div>
      <div className="frames-body" ref={ref}>
        {frames.slice(-200).map((f) => (
          <div key={f.id} className="frame">
            <span className="faint time">{clock(f.at)}</span>
            <span className={f.dir}>{f.dir === 'in' ? '←' : '→'}</span>
            <span className="faint ch">{f.channel}</span>
            <span style={{ overflow: 'hidden', textOverflow: 'ellipsis' }}>
              {f.kind === 'response' ? '↩ ' : ''}
              {f.method}
            </span>
            <span className="p">{JSON.stringify(f.payload)}</span>
          </div>
        ))}
      </div>
    </section>
  );
}
