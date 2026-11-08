import { ArrowUpRight, Monitor, X } from 'lucide-react';
import { useState } from 'react';
import { CardState, cardHref, cardLine, workHref } from '../components/Cards';
import { Toolbar } from '../components/Shell';
import type { AppState, Card } from '../data/model';
import { commentCard, unblockCard } from '../data/store';
import { go } from '../route';
import { Avatar } from '../ui/bits';
import { ago, hm, useNow } from '../ui/format';

const COLUMNS: { key: string; label: string; match: (c: Card) => boolean }[] = [
  { key: 'queue', label: '排队', match: (c) => c.status === 'todo' || c.status === 'ready' },
  { key: 'running', label: '在做', match: (c) => c.status === 'running' },
  { key: 'waiting', label: '等你', match: (c) => c.status === 'blocked' || c.status === 'review' },
  { key: 'done', label: '完成', match: (c) => c.status === 'done' },
];

const who = (state: AppState, id: string) =>
  id === 'you' ? '你' : id.startsWith('routine:') ? `例行「${id.slice(8)}」` : state.bots.find((b) => b.id === id)?.name ?? id;

/**
 * Work handed to assistants, on the Hermes kanban board. 紫苑 creates the
 * cards; each runs in its own worker session; a card that needs you waits in
 * 「等你」 until you comment or unblock it.
 */
export function BoardView({ state, cardId }: { state: AppState; cardId?: string }) {
  const now = useNow(5000);
  const selected = state.cards.find((c) => c.id === cardId);
  const running = state.cards.filter((c) => c.status === 'running').length;
  const waiting = state.cards.filter((c) => c.status === 'blocked' || c.status === 'review').length;
  return (
    <>
      <Toolbar title="看板" sub={`${running} 件在做${waiting ? ` · ${waiting} 件等你` : ''}`} />
      <div className="view split">
        <div className="split-main board-canvas">
          <div className="kb">
            {COLUMNS.map((col) => {
              const cards = state.cards.filter(col.match).sort((a, b) => b.updatedAt - a.updatedAt);
              return (
                <section key={col.key} className={`kb-col kb-${col.key}`}>
                  <h3>
                    {col.label}
                    <span>{cards.length}</span>
                  </h3>
                  {cards.map((c) => {
                    const bot = state.bots.find((b) => b.id === c.assignee);
                    return (
                      <a key={c.id} className={`kb-card${c.id === cardId ? ' on' : ''}`} href={cardHref(c.id)}>
                        <span className="kb-title">{c.title}</span>
                        <span className={`kb-line${col.key === 'waiting' ? ' warm' : ''}`}>{cardLine(c, state, now)}</span>
                        <span className="kb-who">
                          <Avatar bot={bot} size={16} />
                          {bot?.name}
                        </span>
                      </a>
                    );
                  })}
                  {cards.length === 0 && <p className="kb-empty">没有</p>}
                </section>
              );
            })}
          </div>
        </div>
        {selected && <CardInspector card={selected} state={state} now={now} />}
      </div>
    </>
  );
}

function CardInspector({ card, state, now }: { card: Card; state: AppState; now: number }) {
  const [text, setText] = useState('');
  const bot = state.bots.find((b) => b.id === card.assignee);
  const onScreen = state.asks.some((a) => a.cardId === card.id && a.kind === 'takeover');
  const hasLog = !!state.chats[`w:${card.id}`];
  const blocked = card.status === 'blocked';
  return (
    <aside className="insp" aria-label="任务详情">
      <div className="insp-bar">
        <CardState card={card} />
        <button className="icon-btn" onClick={() => go('board')} aria-label="关闭">
          <X size={16} />
        </button>
      </div>
      <div className="insp-body">
        <h2 className="insp-title">{card.title}</h2>
        <p className="insp-meta">
          <a className="inline-link" href={`#chat-${card.assignee}`}>
            <Avatar bot={bot} size={16} />
            {bot?.name}
          </a>
          负责 · {who(state, card.createdBy)}交代的 · {ago(card.createdAt, now)}
        </p>
        <p className="insp-text">{card.body}</p>

        {blocked && card.block && (
          <div className="callout warm">
            <span>{card.block.reason}</span>
            {onScreen && (
              <button className="btn sm primary" onClick={() => go(`desktop-${card.assignee}`)}>
                <Monitor size={13} />
                去云桌面
              </button>
            )}
          </div>
        )}
        {card.summary && <div className="callout">{card.summary}</div>}
        {hasLog && (
          <a className="inline-link more" href={workHref(card.id)}>
            看它是怎么做的 <ArrowUpRight size={12} />
          </a>
        )}

        <section className="insp-sec">
          <h4>留言</h4>
          <p className="quiet small">助手每次开始做都会先读这里。</p>
          {card.comments.map((c, i) => {
            const b = state.bots.find((x) => x.id === c.author);
            return (
              <div key={i} className="note">
                <Avatar bot={b} size={20} />
                <div>
                  <div className="note-head">
                    <b>{c.author === 'you' ? '你' : b?.name ?? c.author}</b>
                    {ago(c.at, now)}
                  </div>
                  <p>{c.body}</p>
                </div>
              </div>
            );
          })}
          <form
            className="inline-form"
            onSubmit={(e) => {
              e.preventDefault();
              if (!text.trim()) return;
              if (blocked) unblockCard(card.id, text.trim());
              else commentCard(card.id, text.trim());
              setText('');
            }}
          >
            <input
              id={`card-note-${card.id}`}
              className="field"
              value={text}
              onChange={(e) => setText(e.target.value)}
              placeholder={blocked ? '补充它需要的信息' : '留言'}
              aria-label="留言"
            />
            <button className="btn primary" type="submit" disabled={!text.trim()}>
              {blocked ? '让它继续' : '发送'}
            </button>
          </form>
        </section>

        {card.runs.length > 0 && (
          <section className="insp-sec">
            <h4>经过</h4>
            <ol className="runs">
              {card.runs.map((r, i) => (
                <li key={r.id}>
                  <span className="runs-n">第 {i + 1} 次</span>
                  <span className="quiet">
                    {hm(r.startedAt)}
                    {r.endedAt ? `–${hm(r.endedAt)}` : ' 开始'}
                  </span>
                  <span className={r.outcome === 'completed' ? 'ok' : r.outcome === 'blocked' ? 'warm' : 'quiet'}>
                    {{ running: '进行中', completed: '做完了', blocked: '停下来等你' }[r.outcome]}
                  </span>
                </li>
              ))}
            </ol>
          </section>
        )}
        <p className="insp-tech">编号 {card.id} · Hermes 看板 default</p>
      </div>
    </aside>
  );
}
