import { ArrowRight, CircleAlert, CircleCheck, LoaderCircle, Play, Send } from 'lucide-react';
import { useEffect, useRef, useState } from 'react';
import type { AppState, Bot, ChatItem } from '../data/model';
import { runRoutine, sendMessage } from '../data/store';
import { AskCard, TodoRow } from '../components/Items';
import { Toolbar } from '../components/Shell';
import { Avatar, BotStatusPill } from '../ui/bits';
import { ago, dayLabel, hm, useNow, when } from '../ui/format';

/**
 * A bot's Bot Chat: the one forever-conversation Hermes Bot Mode keeps per
 * profile (session titled "Bot Chat"). The chief secretary's chat is the
 * default place to talk; every assistant's chat stays reachable on its own.
 */
export function ChatView({ state, botId }: { state: AppState; botId: string }) {
  const now = useNow(5000);
  const bot = state.bots.find((b) => b.id === botId);
  const chat = state.chats[botId];
  const ref = useRef<HTMLDivElement>(null);
  const stick = useRef(true);
  const [text, setText] = useState('');
  const last = chat?.items[chat.items.length - 1];
  const asks = state.asks.filter((a) => a.botId === botId);

  useEffect(() => {
    stick.current = true;
  }, [botId]);
  useEffect(() => {
    const el = ref.current;
    if (el && stick.current) el.scrollTop = el.scrollHeight;
  }, [botId, chat?.items.length, last?.text, asks.length]);

  if (!bot) {
    return (
      <>
        <Toolbar title="找不到这个助手" />
        <div className="view empty">
          <a href="#today">回到今天</a>
        </div>
      </>
    );
  }

  let lastDay = '';
  return (
    <>
      <Toolbar title={bot.chief ? `${bot.name} · 总秘书` : bot.name} sub={`${bot.title} · Bot Chat · ${bot.model}`}>
        <BotStatusPill status={bot.status} />
      </Toolbar>
      <div className="view" style={{ overflow: 'hidden' }}>
        <div className="chat-layout">
          <div className="chat-main">
            <div
              className="transcript"
              ref={ref}
              onScroll={(e) => {
                const el = e.currentTarget;
                stick.current = el.scrollHeight - el.scrollTop - el.clientHeight < 40;
              }}
            >
              {chat?.items.map((it) => {
                const d = dayLabel(it.at, now);
                const sep = d !== lastDay;
                lastDay = d;
                return (
                  <div key={it.id} className="row-wrap">
                    {sep && <div className="day-sep">{d}</div>}
                    <Item it={it} bot={bot} state={state} now={now} />
                  </div>
                );
              })}
              {asks.map((a) => (
                <div key={a.id} className="inline-ask">
                  <AskCard ask={a} state={state} now={now} />
                </div>
              ))}
            </div>
            <form
              className="composer"
              onSubmit={(e) => {
                e.preventDefault();
                if (!text.trim()) return;
                sendMessage(bot.id, text.trim());
                setText('');
                stick.current = true;
              }}
            >
              <input
                id={`composer-${bot.id}`}
                className="field"
                value={text}
                onChange={(e) => setText(e.target.value)}
                placeholder={bot.chief ? '跟紫苑说，需要的话她会转给其他助手…' : `直接跟「${bot.name}」说…`}
              />
              <button className="btn primary" type="submit" disabled={!text.trim()}>
                <Send size={13} />
                发送
              </button>
            </form>
          </div>
          <BotPanel bot={bot} state={state} now={now} />
        </div>
      </div>
    </>
  );
}

function Item({ it, bot, state, now }: { it: ChatItem; bot: Bot; state: AppState; now: number }) {
  if (it.role === 'system') return <div className="sysline">{it.text}</div>;
  if (it.role === 'tool' && it.tool) {
    const t = it.tool;
    return (
      <div className="tool-line" title={t.tool}>
        {t.status === 'running' ? (
          <LoaderCircle size={13} className="spin" color="var(--info)" />
        ) : t.status === 'error' ? (
          <CircleAlert size={13} color="var(--crit)" />
        ) : (
          <CircleCheck size={13} color="var(--good)" />
        )}
        <span>{t.summary}</span>
      </div>
    );
  }
  if (it.role === 'handoff') {
    const to = state.bots.find((b) => b.id === it.to);
    return (
      <div className="msg">
        <div className="who">
          <span>{bot.name}</span>
          <span>{hm(it.at)}</span>
        </div>
        <div className="bubble">{it.text}</div>
        {to && to.id !== bot.id && (
          <a className="handoff" href={`#chat-${to.id}`}>
            <ArrowRight size={12} />
            <Avatar bot={to} size={16} />
            交给了「{to.name}」· 打开它的对话
          </a>
        )}
      </div>
    );
  }
  const user = it.role === 'user';
  const todos = (it.todoIds ?? []).map((id) => state.todos.find((t) => t.id === id)).filter((t): t is NonNullable<typeof t> => !!t);
  return (
    <div className={`msg${user ? ' user' : ''}`}>
      <div className="who">
        <span>{user ? '你' : bot.name}</span>
        <span>{hm(it.at)}</span>
      </div>
      <div className="bubble">
        {it.text}
        {it.streaming && <span className="caret" />}
      </div>
      {todos.length > 0 && !it.streaming && (
        <div className="msg-todos">
          {todos.map((t) => (
            <TodoRow key={t.id} t={t} now={now} />
          ))}
        </div>
      )}
    </div>
  );
}

function BotPanel({ bot, state, now }: { bot: Bot; state: AppState; now: number }) {
  const delegations = state.delegations.filter((d) => d.botId === bot.id && d.state !== 'done');
  return (
    <aside className="bot-side">
      <div className="bot-card-head">
        <Avatar bot={bot} size={44} />
        <div>
          <div className="bn">{bot.name}</div>
          <div className="faint">{bot.title}</div>
        </div>
      </div>
      <p className="muted" style={{ margin: 0 }}>
        {bot.description}
      </p>
      <div className="now-box">
        {bot.status === 'working' && <LoaderCircle size={13} className="spin" color="var(--info)" />}
        <span>{bot.statusNote}</span>
      </div>

      {bot.chief && (
        <section className="side-sec">
          <h3>团队</h3>
          {state.bots
            .filter((b) => !b.chief)
            .map((b) => (
              <a key={b.id} className="team-row" href={`#chat-${b.id}`}>
                <Avatar bot={b} size={22} showStatus />
                <span className="tr-main">
                  <span>{b.name}</span>
                  <span className="faint">{b.statusNote}</span>
                </span>
              </a>
            ))}
        </section>
      )}

      {delegations.length > 0 && (
        <section className="side-sec">
          <h3>正在做</h3>
          {delegations.map((d) => (
            <div key={d.id} className="mini-del">
              <div>{d.title}</div>
              <div className="faint">
                {d.note} · {ago(d.updatedAt, now)}
              </div>
            </div>
          ))}
        </section>
      )}

      <section className="side-sec">
        <h3>例行</h3>
        {bot.routines.map((r) => (
          <div key={r.id} className="routine">
            <div className="rt-top">
              <span className="rt-name">{r.name}</span>
              <button className="btn ghost mini" onClick={() => runRoutine(bot.id, r.name)} title="现在运行一次（cron.submit）">
                <Play size={11} />
                现在运行
              </button>
            </div>
            <div className="faint">{r.schedule}</div>
            <div className="faint">
              {r.nextRunAt ? `下次 ${when(r.nextRunAt, now)}` : ''}
              {r.lastRun ? ` · 上次 ${r.lastRun.note ?? (r.lastRun.ok ? '成功' : '失败')}` : ''}
            </div>
          </div>
        ))}
      </section>

      <section className="side-sec">
        <h3>能用的工具</h3>
        <div className="chips">
          {bot.tools.map((t) => (
            <span key={t} className="chip">
              {t}
            </span>
          ))}
        </div>
        <div className="faint" style={{ fontSize: 11.5 }}>
          profile: {bot.id} · {bot.model}
        </div>
      </section>
    </aside>
  );
}
