import { Circle, CircleCheck, CircleDot, Eye, Hand, LoaderCircle, OctagonAlert, SquareKanban, type LucideIcon } from 'lucide-react';
import type { AppState, Card, CardStatus } from '../data/model';
import { Avatar } from '../ui/bits';

export const cardHref = (id: string) => `#card-${id.replace(/^t_/, '')}`;
export const workHref = (id: string) => `#work-${id.replace(/^t_/, '')}`;

const STATUS: Record<CardStatus, { label: string; tone: string; icon: LucideIcon }> = {
  todo: { label: '排队', tone: 'neutral', icon: Circle },
  ready: { label: '就绪', tone: 'accent', icon: CircleDot },
  running: { label: '进行中', tone: 'info', icon: LoaderCircle },
  blocked: { label: '等你', tone: 'warning', icon: Hand },
  review: { label: '待审', tone: 'warning', icon: Eye },
  done: { label: '完成', tone: 'good', icon: CircleCheck },
};

export function CardStatusPill({ card }: { card: Card }) {
  const blockedHard = card.status === 'blocked' && card.block?.kind !== 'needs_input';
  const s = blockedHard ? { label: '受阻', tone: 'critical', icon: OctagonAlert } : STATUS[card.status];
  const Icon = s.icon;
  return (
    <span className={`pill tone-${s.tone}`}>
      <Icon size={11} className={card.status === 'running' ? 'spin' : undefined} />
      {s.label}
    </span>
  );
}

/** A live reference to a kanban card, as it appears inside a chat or a list. */
export function CardChip({ card, state }: { card: Card; state: AppState }) {
  const bot = state.bots.find((b) => b.id === card.assignee);
  return (
    <a className="card-chip" href={cardHref(card.id)}>
      <SquareKanban size={14} className="cc-icon" />
      <span className="cc-main">
        <span className="cc-title">{card.title}</span>
        <span className="cc-sub">
          <span className="mono">{card.id}</span> · 交给「{bot?.name}」
          {card.status === 'done' && card.summary ? ` · ${card.summary}` : card.status === 'blocked' && card.block ? ` · ${card.block.reason}` : ''}
        </span>
      </span>
      <Avatar bot={bot} size={18} />
      <CardStatusPill card={card} />
    </a>
  );
}
