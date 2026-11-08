import { ArrowRight, GitBranch, HeartPulse, MessageSquare, Monitor, X } from 'lucide-react';
import { useState } from 'react';
import { CardStatusPill, cardHref, workHref } from '../components/Cards';
import { Toolbar } from '../components/Shell';
import type { AppState, Card } from '../data/model';
import { commentCard, unblockCard } from '../data/store';
import { go } from '../route';
import { Avatar } from '../ui/bits';
import { ago, hm, useNow } from '../ui/format';

const COLUMNS: { key: string; label: string; hint: string; match: (c: Card) => boolean }[] = [
  { key: 'queue', label: '排队', hint: 'todo · ready', match: (c) => c.status === 'todo' || c.status === 'ready' },
  { key: 'running', label: '进行中', hint: 'running', match: (c) => c.status === 'running' },
  { key: 'waiting', label: '等你', hint: 'blocked · review', match: (c) => c.status === 'blocked' || c.status === 'review' },
  { key: 'done', label: '完成', hint: 'done', match: (c) => c.status === 'done' },
];

const who = (state: AppState, id: string) =>
  id === 'you' ? '你' : id.startsWith('routine:') ? `例行「${id.slice(8)}」` : state.bots.find((b) => b.id === id)?.name ?? id;

/**
 * The Hermes kanban board as the place where work handed to assistants lives:
 * 紫苑 creates cards, the dispatcher runs them as worker sessions, and a card
 * that needs you waits in 「等你」 until you comment or unblock it.
 */
export function BoardView({ state, cardId }: { state: AppState; cardId?: string }) {
  const now = useNow(5000);
  const selected = state.cards.find((c) => c.id === cardId);
  return (
    <>
      <Toolbar title="看板" sub="交给助手的事 · Hermes 看板 default · 紫苑创建，派发器每 60 秒派一次" />
      <div className="view" style={{ overflow: 'hidden' }}>
        <div className="split">
          <div className="split-main">
            <div className="kb">
              {COLUMNS.map((col) => {
                const cards = state.cards.filter(col.match).sort((a, b) => b.updatedAt - a.updatedAt);
                return (
                  <section key={col.key} className={`kb-col kb-${col.key}`}>
                    <h3>
                      {col.label} <span className="faint num">{cards.length}</span>
                      <span className="mono faint kb-hint">{col.hint}</span>
                    </h3>
                    {cards.map((c) => (
                      <CardTile key={c.id} card={c} state={state} now={now} selected={c.id === cardId} />
                    ))}
                    {cards.length === 0 && <div className="faint empty-col">没有</div>}
                  </section>
                );
              })}
            </div>
          </div>
          {selected && <CardInspector card={selected} state={state} now={now} />}
        </div>
      </div>
    </>
  );
}

function CardTile({ card, state, now, selected }: { card: Card; state: AppState; now: number; selected: boolean }) {
  const bot = state.bots.find((b) => b.id === card.assignee);
  return (
    <a className={`panel kb-card${selected ? ' on' : ''}`} href={cardHref(card.id)}>
      <div className="kc-top">
        <span className="mono faint">{card.id}</span>
        <CardStatusPill card={card} />
      </div>
      <div className="kc-title">{card.title}</div>
      {card.status === 'running' && card.heartbeat && (
        <div className="kc-line">
          <HeartPulse size={12} color="var(--info)" />
          <span>
            {ago(card.heartbeat.at, now)} · {card.heartbeat.note}
          </span>
        </div>
      )}
      {card.status === 'blocked' && card.block && <div className="kc-line warn">{card.block.reason}</div>}
      {card.status === 'done' && card.summary && <div className="kc-line muted">{card.summary}</div>}
      {card.status === 'todo' && card.parents?.length ? (
        <div className="kc-line faint">
          <GitBranch size={12} />等 {card.parents.join('、')} 完成
        </div>
      ) : null}
      <div className="kc-foot">
        <Avatar bot={bot} size={18} />
        <span>{bot?.name}</span>
        <span className="faint">· {who(state, card.createdBy)}创建</span>
        {card.comments.length > 0 && (
          <span className="faint kc-com">
            <MessageSquare size={11} />
            {card.comments.length}
          </span>
        )}
      </div>
    </a>
  );
}

function CardInspector({ card, state, now }: { card: Card; state: AppState; now: number }) {
  const [text, setText] = useState('');
  const bot = state.bots.find((b) => b.id === card.assignee);
  const screenAsk = state.asks.find((a) => a.cardId === card.id && a.kind === 'takeover');
  const hasWork = !!state.chats[`w:${card.id}`];
  return (
    <aside className="inspector" aria-label="任务卡详情">
      <div className="insp-head">
        <span className="mono faint">{card.id}</span>
        <CardStatusPill card={card} />
        <button className="btn ghost icon" style={{ marginLeft: 'auto' }} onClick={() => go('board')} aria-label="关闭">
          <X size={15} />
        </button>
      </div>
      <div className="insp-body">
        <h2 className="insp-title">{card.title}</h2>
        <dl className="props">
          <dt>负责</dt>
          <dd>
            <a className="chip" href={`#chat-${card.assignee}`}>
              <Avatar bot={bot} size={14} />
              {bot?.name}
            </a>
          </dd>
          <dt>创建</dt>
          <dd className="muted">
            {who(state, card.createdBy)} · {ago(card.createdAt, now)}
          </dd>
          {card.parents?.length ? (
            <>
              <dt>依赖</dt>
              <dd>
                {card.parents.map((p) => (
                  <a key={p} className="chip mono" href={cardHref(p)}>
                    {p}
                  </a>
                ))}
              </dd>
            </>
          ) : null}
        </dl>
        <p className="body-text">{card.body}</p>

        {card.status === 'blocked' && card.block && (
          <div className="block-box">
            <strong>{card.block.kind === 'needs_input' ? '等你：' : '受阻：'}</strong>
            {card.block.reason}
            {screenAsk && (
              <button className="btn primary mini" onClick={() => go(`desktop-${card.assignee}`)}>
                <Monitor size={12} />
                去云桌面接管
              </button>
            )}
          </div>
        )}
        {card.summary && (
          <div className="summary-box">
            <span className="faint">结果</span>
            {card.summary}
          </div>
        )}
        {hasWork && (
          <a className="btn" href={workHref(card.id)}>
            看工作记录 <ArrowRight size={12} />
          </a>
        )}

        <section className="side-sec">
          <h3>评论（助手每次运行都会读到）</h3>
          {card.comments.length === 0 && <span className="faint">还没有评论</span>}
          {card.comments.map((c, i) => {
            const b = state.bots.find((x) => x.id === c.author);
            return (
              <div key={i} className="comment">
                <Avatar bot={b} size={20} />
                <div style={{ minWidth: 0 }}>
                  <div className="meta">
                    <b>{c.author === 'you' ? '你' : b?.name ?? c.author}</b>
                    {ago(c.at, now)}
                  </div>
                  <p>{c.body}</p>
                </div>
              </div>
            );
          })}
          <form
            className="actions"
            onSubmit={(e) => {
              e.preventDefault();
              if (!text.trim()) return;
              if (card.status === 'blocked') unblockCard(card.id, text.trim());
              else commentCard(card.id, text.trim());
              setText('');
            }}
          >
            <input
              id={`card-comment-${card.id}`}
              className="field"
              style={{ flex: 1 }}
              value={text}
              onChange={(e) => setText(e.target.value)}
              placeholder={card.status === 'blocked' ? '写下补充的信息，解除阻塞后重新运行' : '留评论，下次运行时助手会读到'}
            />
            <button className="btn primary" type="submit" disabled={!text.trim()}>
              {card.status === 'blocked' ? '解除阻塞' : '评论'}
            </button>
          </form>
        </section>

        <section className="side-sec">
          <h3>运行记录</h3>
          {card.runs.length === 0 && <span className="faint">还没运行过</span>}
          {[...card.runs].reverse().map((r, i) => (
            <div key={r.id} className="run-row">
              <span className="mono faint">#{card.runs.length - i}</span>
              <span>
                {hm(r.startedAt)}
                {r.endedAt ? `–${hm(r.endedAt)}` : ' 起'}
              </span>
              <span className={`pill tone-${r.outcome === 'completed' ? 'good' : r.outcome === 'running' ? 'info' : 'warning'}`}>
                {{ running: '运行中', completed: '完成', blocked: '阻塞' }[r.outcome]}
              </span>
              {r.note && <span className="faint run-note">{r.note}</span>}
            </div>
          ))}
        </section>
      </div>
    </aside>
  );
}
