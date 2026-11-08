import { ArrowUp, ArrowUpRight, Check, CircleAlert } from 'lucide-react';
import { useEffect, useRef, useState } from 'react';
import { CardChip, CardRow, CardState, cardHref, workHref } from '../components/Cards';
import { AskCard, TodoRow } from '../components/Items';
import { ScreenMock } from '../components/Screen';
import { Toolbar } from '../components/Shell';
import type { AppState, Bot, Chat, ChatItem } from '../data/model';
import { runRoutine, sendMessage } from '../data/store';
import { go } from '../route';
import { Avatar, Busy, botMood } from '../ui/bits';
import { dayLabel, hm, useNow, when } from '../ui/format';

/**
 * One assistant. 「对话」 is its Bot Chat, the single forever-conversation Bot
 * Mode keeps per profile. 「工作记录」 lists the worker sessions the kanban
 * dispatcher ran for its cards, newest first.
 */
export function ChatView({ state, botId, focusCard }: { state: AppState; botId: string; focusCard?: string }) {
  const now = useNow(5000);
  const bot = state.bots.find((b) => b.id === botId);
  const workers = Object.values(state.chats)
    .filter((c) => c.kind === 'worker' && c.botId === botId)
    .sort((a, b) => (state.cards.find((x) => x.id === b.cardId)?.createdAt ?? 0) - (state.cards.find((x) => x.id === a.cardId)?.createdAt ?? 0));
  const tab = focusCard ? 'work' : 'talk';

  if (!bot) {
    return (
      <>
        <Toolbar title="找不到这个助手" />
        <div className="view empty-state">
          <a href="#today">回到今天</a>
        </div>
      </>
    );
  }

  return (
    <>
      <Toolbar title={bot.name} sub={bot.title} ask={false}>
        {workers.length > 0 && (
          <div className="seg" role="tablist" aria-label="视图">
            <button role="tab" aria-pressed={tab === 'talk'} onClick={() => go(`chat-${botId}`)}>
              对话
            </button>
            <button role="tab" aria-pressed={tab === 'work'} onClick={() => go(workHref(workers[0].cardId!).slice(1))}>
              工作记录 <span className="seg-n">{workers.length}</span>
            </button>
          </div>
        )}
      </Toolbar>
      <div className="view chat">
        <div className="chat-main">
          {tab === 'talk' ? (
            <>
              <Conversation chat={state.chats[botId]} bot={bot} state={state} now={now} />
              <Composer bot={bot} />
            </>
          ) : (
            <WorkLog workers={workers} bot={bot} state={state} now={now} focus={focusCard} />
          )}
        </div>
        <BotSide bot={bot} state={state} now={now} />
      </div>
    </>
  );
}

type Block = { key: string; at: number } & ({ kind: 'item'; it: ChatItem } | { kind: 'steps'; items: ChatItem[] });

/** Fold consecutive tool steps into one block so a conversation reads as sentences, not logs. */
function blocks(items: ChatItem[]): Block[] {
  const out: Block[] = [];
  for (const it of items) {
    const last = out[out.length - 1];
    if (it.role === 'tool' && last?.kind === 'steps') last.items.push(it);
    else if (it.role === 'tool') out.push({ key: it.id, at: it.at, kind: 'steps', items: [it] });
    else out.push({ key: it.id, at: it.at, kind: 'item', it });
  }
  return out;
}

function Feed({ items, bot, state, now, heads = true }: { items: ChatItem[]; bot: Bot; state: AppState; now: number; heads?: boolean }) {
  let day = '';
  // who spoke last, so a run of the assistant's messages shows its name once
  let speaker: 'bot' | 'you' | null = null;
  let lastBotAt = 0;
  return (
    <>
      {blocks(items).map((b) => {
        const d = dayLabel(b.at, now);
        const sep = heads && d !== day;
        day = d;
        let head = false;
        if (b.kind === 'item') {
          const role = b.it.role;
          if (role === 'assistant') {
            head = heads && (speaker !== 'bot' || b.at - lastBotAt > 10 * 60_000);
            speaker = 'bot';
            lastBotAt = b.at;
          } else if (role === 'user') speaker = 'you';
          else speaker = null;
        }
        return (
          <div key={b.key} className="feed-row">
            {sep && <div className="day">{d}</div>}
            {b.kind === 'steps' ? <Steps items={b.items} /> : <Item it={b.it} bot={bot} state={state} now={now} head={head} />}
          </div>
        );
      })}
    </>
  );
}

function Conversation({ chat, bot, state, now }: { chat?: Chat; bot: Bot; state: AppState; now: number }) {
  const ref = useRef<HTMLDivElement>(null);
  const stick = useRef(true);
  const items = chat?.items ?? [];
  const last = items[items.length - 1];
  const asks = state.asks.filter((a) => a.botId === bot.id);
  useEffect(() => {
    stick.current = true;
  }, [bot.id]);
  useEffect(() => {
    const el = ref.current;
    if (el && stick.current) el.scrollTop = el.scrollHeight;
  }, [bot.id, items.length, last?.text, asks.length]);
  return (
    <div
      className="convo"
      ref={ref}
      onScroll={(e) => {
        const el = e.currentTarget;
        stick.current = el.scrollHeight - el.scrollTop - el.clientHeight < 40;
      }}
    >
      <div className="convo-inner">
        <Feed items={items} bot={bot} state={state} now={now} />
        {asks.map((a) => (
          <AskCard key={a.id} ask={a} state={state} now={now} />
        ))}
      </div>
    </div>
  );
}

function Item({ it, bot, state, now, head }: { it: ChatItem; bot: Bot; state: AppState; now: number; head: boolean }) {
  if (it.role === 'system') return <div className="sys">{it.text}</div>;
  if (it.role === 'card') {
    const card = state.cards.find((c) => c.id === it.cardId);
    return card ? <CardChip card={card} state={state} /> : null;
  }
  if (it.role === 'user') {
    return (
      <div className="m-you">
        <div className="bubble">{it.text}</div>
      </div>
    );
  }
  const todos = (it.todoIds ?? []).map((id) => state.todos.find((t) => t.id === id)).filter((t): t is NonNullable<typeof t> => !!t);
  return (
    <div className="m-bot">
      {head && (
        <div className="m-head">
          <Avatar bot={bot} size={18} />
          <b>{bot.name}</b>
          <span>{hm(it.at)}</span>
        </div>
      )}
      <div className="m-text">
        {it.text}
        {it.streaming && <span className="caret" />}
      </div>
      {todos.length > 0 && !it.streaming && (
        <div className="embed">
          {todos.map((t) => (
            <TodoRow key={t.id} t={t} now={now} />
          ))}
        </div>
      )}
    </div>
  );
}

function Steps({ items }: { items: ChatItem[] }) {
  const [open, setOpen] = useState(false);
  const running = items.find((i) => i.tool?.status === 'running');
  const shown = open ? items : [running ?? items[items.length - 1]];
  return (
    <div className="steps">
      {shown.map((i) => (
        <div key={i.id} className="step" title={i.tool!.tool}>
          {i.tool!.status === 'running' ? (
            <span className="spinner" />
          ) : i.tool!.status === 'error' ? (
            <CircleAlert size={13} className="red" />
          ) : (
            <Check size={13} strokeWidth={2.4} />
          )}
          <span>{i.tool!.summary}</span>
        </div>
      ))}
      {items.length > 1 && (
        <button className="steps-more" onClick={() => setOpen((x) => !x)}>
          {open ? '收起' : `共 ${items.length} 步`}
        </button>
      )}
    </div>
  );
}

function Composer({ bot }: { bot: Bot }) {
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
      <div className="composer-box">
        <input id={`composer-${bot.id}`} value={text} onChange={(e) => setText(e.target.value)} placeholder={`跟${bot.name}说…`} aria-label={`跟${bot.name}说`} />
        <button className="send" type="submit" disabled={!text.trim()} aria-label="发送">
          <ArrowUp size={15} strokeWidth={2.4} />
        </button>
      </div>
    </form>
  );
}

function WorkLog({ workers, bot, state, now, focus }: { workers: Chat[]; bot: Bot; state: AppState; now: number; focus?: string }) {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    ref.current?.querySelector('.wl.focus')?.scrollIntoView({ block: 'start' });
  }, [focus]);
  return (
    <div className="convo" ref={ref}>
      <div className="convo-inner">
        <p className="quiet small">看板把每件事交给{bot.name}时，都会单独开一段工作记录，和你们的对话分开。</p>
        {workers.map((w) => {
          const card = state.cards.find((c) => c.id === w.cardId)!;
          return (
            <section key={w.key} className={`wl${w.cardId === focus ? ' focus' : ''}`}>
              <header className="wl-head">
                <span className="wl-title">{card.title}</span>
                <CardState card={card} />
              </header>
              <p className="wl-meta">
                {card.createdBy === 'you' ? '你' : state.bots.find((b) => b.id === card.createdBy)?.name ?? '例行任务'}交代的 · {hm(card.createdAt)}
                <a className="inline-link" href={cardHref(card.id)}>
                  在看板里打开 <ArrowUpRight size={11} />
                </a>
              </p>
              <div className="wl-body">
                <Feed items={w.items} bot={bot} state={state} now={now} heads={false} />
              </div>
            </section>
          );
        })}
      </div>
    </div>
  );
}

function BotSide({ bot, state, now }: { bot: Bot; state: AppState; now: number }) {
  const mood = botMood(bot, state.asks.some((a) => a.botId === bot.id));
  const cards = state.cards
    .filter((c) => (bot.chief ? c.createdBy === bot.id : c.assignee === bot.id) && c.status !== 'done')
    .sort((a, b) => b.updatedAt - a.updatedAt);
  const screen = state.screens[bot.id];
  return (
    <aside className="bside">
      <div className="bside-head">
        <Avatar bot={bot} size={44} />
        <div>
          <div className="bside-name">{bot.name}</div>
          <div className="quiet">{bot.title}</div>
        </div>
      </div>
      <p className="bside-desc">{bot.description}</p>
      <div className={`bside-now ${mood}`}>
        {mood === 'busy' ? <Busy /> : <span className="mood-dot" />}
        <span>{bot.statusNote}</span>
      </div>

      {screen?.running && (
        <a className="bside-screen" href={`#desktop-${bot.id}`} aria-label={`打开${bot.name}的云桌面`}>
          <ScreenMock screen={screen} />
          <span>
            云桌面 · {screen.control === 'you' ? '你在操作' : screen.needsHuman ? '等你接管' : screen.activity}
          </span>
        </a>
      )}

      {cards.length > 0 && (
        <section className="bside-sec">
          <h4>{bot.chief ? '在跟进' : '在做的事'}</h4>
          <div className="list tight">
            {cards.map((c) => (
              <CardRow key={c.id} card={c} state={state} now={now} />
            ))}
          </div>
        </section>
      )}

      <section className="bside-sec">
        <h4>例行</h4>
        {bot.routines.map((r) => (
          <div key={r.id} className="routine">
            <div className="routine-main">
              <span className="routine-name">{r.name}</span>
              <span className="quiet">{r.schedule}</span>
              {r.nextRunAt && <span className="quiet">下次 {when(r.nextRunAt, now)}</span>}
            </div>
            <button className="link-btn" onClick={() => runRoutine(bot.id, r.name)}>
              现在运行
            </button>
          </div>
        ))}
      </section>

      <section className="bside-sec">
        <h4>能做的事</h4>
        <p className="bside-tools">{bot.tools.join('、')}</p>
        <p className="tech">
          {bot.model} · profile {bot.id}
        </p>
      </section>
    </aside>
  );
}
