import { Check, SquareKanban } from 'lucide-react';
import type { AppState, Card } from '../data/model';
import { Avatar, Busy } from '../ui/bits';
import { ago } from '../ui/format';

export const cardHref = (id: string) => `#card-${id.replace(/^t_/, '')}`;
export const workHref = (id: string) => `#work-${id.replace(/^t_/, '')}`;

/** A card's state as one quiet tag: breathing dots, a warm "等你", a check, or plain words. */
export function CardState({ card }: { card: Card }) {
  switch (card.status) {
    case 'running':
      return (
        <span className="state busy-state">
          <Busy />
          在做
        </span>
      );
    case 'blocked':
    case 'review':
      return <span className={`state ${card.block && card.block.kind !== 'needs_input' ? 'red' : 'warm'}`}>{card.status === 'review' ? '待你审阅' : card.block?.kind === 'needs_input' ? '等你' : '卡住了'}</span>;
    case 'done':
      return (
        <span className="state done">
          <Check size={12} strokeWidth={2.6} />
          完成
        </span>
      );
    default:
      return <span className="state">{card.status === 'todo' ? '排队' : '就绪'}</span>;
  }
}

/** The line under a card's title: what it is doing, waiting on, or delivered. */
export function cardLine(card: Card, state: AppState, now: number): string {
  if (card.status === 'running') return card.heartbeat ? `${card.heartbeat.note} · ${ago(card.heartbeat.at, now)}` : '刚开始';
  if (card.status === 'blocked' || card.status === 'review') return card.block?.reason ?? '等你看一下';
  if (card.status === 'done') return card.summary ?? '完成了';
  if (card.status === 'todo' && card.parents?.length) {
    const parent = state.cards.find((c) => c.id === card.parents![0]);
    return parent ? `等「${parent.title}」做完` : '等前一件做完';
  }
  return queueReason(card, state);
}

/** Why a ready card has not started yet, in the dispatcher's own terms. */
export function queueReason(card: Card, state: AppState): string {
  const running = state.cards.filter((c) => c.status === 'running');
  const { maxInProgress, perProfile } = state.dispatch;
  const name = state.bots.find((b) => b.id === card.assignee)?.name ?? '它';
  if (perProfile && running.filter((c) => c.assignee === card.assignee).length >= perProfile) return `${name}手上还有一件，做完就开始`;
  if (maxInProgress && running.length >= maxInProgress) return `同时在做的已满 ${maxInProgress} 件，空出来就开始`;
  return '下一轮派发就开始';
}

export function CardRow({ card, state, now }: { card: Card; state: AppState; now: number }) {
  const bot = state.bots.find((b) => b.id === card.assignee);
  const warm = card.status === 'blocked' || card.status === 'review';
  return (
    <a className="row" href={cardHref(card.id)}>
      <Avatar bot={bot} size={24} />
      <span className="row-main">
        <span className="row-title">{card.title}</span>
        <span className={`row-sub${warm ? ' warm' : ''}`}>{cardLine(card, state, now)}</span>
      </span>
      <CardState card={card} />
    </a>
  );
}

/** A card as it appears inside a conversation: what was handed to whom, and how it is going. */
export function CardChip({ card, state }: { card: Card; state: AppState }) {
  const bot = state.bots.find((b) => b.id === card.assignee);
  return (
    <a className="card-chip" href={cardHref(card.id)}>
      <SquareKanban size={15} className="card-chip-icon" />
      <span className="card-chip-main">
        <span className="card-chip-title">{card.title}</span>
        <span className="card-chip-sub">交给「{bot?.name}」</span>
      </span>
      <CardState card={card} />
    </a>
  );
}
