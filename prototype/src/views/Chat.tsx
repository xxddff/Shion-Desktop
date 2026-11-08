import { CircleAlert, CircleCheck, LoaderCircle, MessageSquare, Play, Send, SquareKanban } from 'lucide-react';
import { useEffect, useRef, useState } from 'react';
import { CardChip, CardStatusPill, cardHref } from '../components/Cards';
import { AskCard, TodoRow } from '../components/Items';
import { ScreenMock } from '../components/Screen';
import { Toolbar } from '../components/Shell';
import type { AppState, Bot, Chat, ChatItem } from '../data/model';
import { commentCard, runRoutine, sendMessage } from '../data/store';
import { go } from '../route';
import { Avatar, BotStatusPill } from '../ui/bits';
import { dayLabel, hm, useNow, when } from '../ui/format';
import { ControlChip } from './Desktop';

/**
 * One assistant: its Bot Chat (the single forever-conversation Bot Mode keeps
 * per profile, where you talk to it directly) plus a tab per kanban card it
 * has run today (the worker session the dispatcher spawned for that card).
 */
export function ChatView({ state, botId, sessionKey }: { state: AppState; botId: string; sessionKey?: string }) {
  const now = useNow(5000);
  const bot = state.bots.find((b) => b.id === botId);
  const workers = Object.values(state.chats)
    .filter((c) => c.kind === 'worker' && c.botId === botId)
    .sort((a, b) => (state.cards.find((x) => x.id === b.cardId)?.createdAt ?? 0) - (state.cards.find((x) => x.id === a.cardId)?.createdAt ?? 0));
  const key = sessionKey && state.chats[sessionKey] ? sessionKey : botId;
  const chat = state.chats[key];

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

  return (
    <>
      <Toolbar title={bot.chief ? `${bot.name} · 总秘书` : bot.name} sub={`${bot.title} · ${bot.model}`}>
        <BotStatusPill status={bot.status} />
      </Toolbar>
      <div className="view" style={{ overflow: 'hidden' }}>
        <div className="chat-layout">
          <div className="chat-main">
            {workers.length > 0 && (
              <div className="session-tabs" role="tablist" aria-label="会话">
                <button role="tab" aria-selected={key === botId} onClick={() => go(`chat-${botId}`)}>
                  <MessageSquare size={13} />
                  Bot Chat
                </button>
                {workers.map((w) => {
                  const card = state.cards.find((c) => c.id === w.cardId);
                  return (
                    <button key={w.key} role="tab" aria-selected={key === w.key} onClick={() => go(`work-${w.cardId!.slice(2)}`)} title={card?.title}>
                      <SquareKanban size={13} />
                      <span className="mono">{w.cardId}</span>
                      {card && <CardStatusPill card={card} />}
                    </button>
                  );
                })}
              </div>
            )}
            {chat && <Transcript chat={chat} bot={bot} state={state} now={now} />}
            {chat?.kind === 'worker' ? <WorkerComposer chat={chat} state={state} /> : <BotComposer bot={bot} />}
          </div>
          <BotPanel bot={bot} state={state} now={now} />
        </div>
      </div>
    </>
  );
}

function Transcript({ chat, bot, state, now }: { chat: Chat; bot: Bot; state: AppState; now: number }) {
  const ref = useRef<HTMLDivElement>(null);
  const stick = useRef(true);
  const last = chat.items[chat.items.length - 1];
  const asks = chat.kind === 'bot' ? state.asks.filter((a) => a.botId === bot.id) : state.asks.filter((a) => a.cardId === chat.cardId);
  const card = chat.cardId ? state.cards.find((c) => c.id === chat.cardId) : undefined;

  useEffect(() => {
    stick.current = true;
  }, [chat.key]);
  useEffect(() => {
    const el = ref.current;
    if (el && stick.current) el.scrollTop = el.scrollHeight;
  }, [chat.key, chat.items.length, last?.text, asks.length]);

  let lastDay = '';
  return (
    <div
      className="transcript"
      ref={ref}
      onScroll={(e) => {
        const el = e.currentTarget;
        stick.current = el.scrollHeight - el.scrollTop - el.clientHeight < 40;
      }}
    >
      {card && (
        <div className="worker-head">
          <CardChip card={card} state={state} />
          <span className="faint">这是看板派发器为这张卡启动的工作会话，和 {bot.name} 的 Bot Chat 分开。想补充信息就给卡留评论。</span>
        </div>
      )}
      {chat.items.map((it) => {
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
  );
}

function Item({ it, bot, state, now }: { it: ChatItem; bot: Bot; state: AppState; now: number }) {
  if (it.role === 'system') return <div className="sysline">{it.text}</div>;
  if (it.role === 'card') {
    const card = state.cards.find((c) => c.id === it.cardId);
    return card ? (
      <div className="msg-card">
        <CardChip card={card} state={state} />
      </div>
    ) : null;
  }
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

function BotComposer({ bot }: { bot: Bot }) {
  const [text, setText] = useState('');
  return (
    <form
      className="composer"
      onSubmit={(e) => {
        e.preventDefault();
        if (!text.trim()) return;
        sendMessage(bot.id, text.trim());
        setText('');
      }}
    >
      <input
        id={`composer-${bot.id}`}
        className="field"
        value={text}
        onChange={(e) => setText(e.target.value)}
        placeholder={bot.chief ? '跟紫苑说；要花时间的事她会建卡交给助手' : `直接跟「${bot.name}」说…`}
      />
      <button className="btn primary" type="submit" disabled={!text.trim()}>
        <Send size={13} />
        发送
      </button>
    </form>
  );
}

function WorkerComposer({ chat, state }: { chat: Chat; state: AppState }) {
  const [text, setText] = useState('');
  const card = state.cards.find((c) => c.id === chat.cardId);
  return (
    <form
      className="composer"
      onSubmit={(e) => {
        e.preventDefault();
        if (!text.trim() || !card) return;
        commentCard(card.id, text.trim());
        setText('');
      }}
    >
      <input id={`comment-${chat.key}`} className="field" value={text} onChange={(e) => setText(e.target.value)} placeholder="给这张卡留评论，下次运行时助手会读到" />
      <button className="btn" type="submit" disabled={!text.trim()}>
        <MessageSquare size={13} />
        评论
      </button>
    </form>
  );
}

function BotPanel({ bot, state, now }: { bot: Bot; state: AppState; now: number }) {
  const cards = state.cards
    .filter((c) => (bot.chief ? c.createdBy === bot.id : c.assignee === bot.id) && c.status !== 'done')
    .sort((a, b) => b.updatedAt - a.updatedAt);
  const screen = state.screens[bot.id];
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

      {screen && (
        <a className="side-screen" href={`#desktop-${bot.id}`} aria-label={`打开${bot.name}的云桌面`}>
          <ScreenMock screen={screen} />
          <span className="ss-meta">
            <span className="grow">云桌面</span>
            <ControlChip screen={screen} />
          </span>
        </a>
      )}

      <section className="side-sec">
        <h3>{bot.chief ? '她建的卡' : '手上的卡'}</h3>
        {cards.length === 0 && <span className="faint">没有进行中的卡</span>}
        {cards.map((c) => {
          const a = state.bots.find((b) => b.id === c.assignee);
          return (
            <a key={c.id} className="mini-card" href={cardHref(c.id)}>
              <span className="mc-top">
                <span className="mono faint">{c.id}</span>
                <CardStatusPill card={c} />
              </span>
              <span>{c.title}</span>
              {bot.chief && <span className="faint">交给「{a?.name}」</span>}
            </a>
          );
        })}
        <a className="btn ghost mini" href="#board" style={{ justifySelf: 'start' }}>
          打开看板
        </a>
      </section>

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
