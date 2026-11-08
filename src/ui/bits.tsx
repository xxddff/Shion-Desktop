import {
  CircleCheck,
  Circle,
  CircleDot,
  Eye,
  Hash,
  Inbox,
  LoaderCircle,
  MessagesSquare,
  Moon,
  OctagonAlert,
  Pause,
  Plug,
  Send,
  Smartphone,
  SquareKanban,
  Terminal,
  CircleOff,
  type LucideIcon,
} from 'lucide-react';
import type { CSSProperties } from 'react';
import type { KanbanTask, TaskStatus } from '../protocol/kanban';
import type { ActivityTone, Bot, BotStatus, PlatformKind } from '../data/model';

export function Avatar({ bot, size = 22, showStatus = false }: { bot?: Bot; size?: number; showStatus?: boolean }) {
  const style = { '--size': `${size}px`, '--c': bot ? `var(--id-${bot.hue})` : undefined } as CSSProperties;
  return (
    <span className={`avatar${bot ? '' : ' you'}`} style={style} aria-hidden="true">
      {bot ? bot.displayName[0] : '你'}
      {bot && showStatus && <span className={`status dot ${BOT_STATUS[bot.status].tone}`} />}
    </span>
  );
}

export const BOT_STATUS: Record<BotStatus, { label: string; tone: ActivityTone; icon: LucideIcon }> = {
  working: { label: '工作中', tone: 'info', icon: LoaderCircle },
  online: { label: '在线', tone: 'good', icon: Circle },
  idle: { label: '空闲', tone: 'neutral', icon: Moon },
  cooldown: { label: '受阻', tone: 'warning', icon: Pause },
  offline: { label: '离线', tone: 'neutral', icon: CircleOff },
};

export function BotStatusPill({ status }: { status: BotStatus }) {
  const s = BOT_STATUS[status];
  const Icon = s.icon;
  return (
    <span className={`pill tone-${s.tone}`}>
      <Icon size={11} strokeWidth={2.4} className={status === 'working' ? 'spin' : undefined} fill={status === 'online' ? 'currentColor' : 'none'} />
      {s.label}
    </span>
  );
}

export type Tone = ActivityTone | 'accent';

export const TASK_STATUS: Record<TaskStatus, { label: string; tone: Tone; icon: LucideIcon }> = {
  triage: { label: '待分拣', tone: 'neutral', icon: Inbox },
  todo: { label: '待办', tone: 'neutral', icon: Circle },
  ready: { label: '就绪', tone: 'accent', icon: CircleDot },
  running: { label: '运行中', tone: 'info', icon: LoaderCircle },
  blocked: { label: '阻塞', tone: 'critical', icon: OctagonAlert },
  review: { label: '待审', tone: 'warning', icon: Eye },
  done: { label: '完成', tone: 'good', icon: CircleCheck },
  archived: { label: '归档', tone: 'neutral', icon: Circle },
};

export function TaskStatusIcon({ status, size = 14 }: { status: TaskStatus; size?: number }) {
  const s = TASK_STATUS[status];
  const Icon = s.icon;
  const color = `var(--${toneVar(s.tone)})`;
  return <Icon size={size} color={color} strokeWidth={2.2} className={status === 'running' ? 'spin' : undefined} aria-hidden="true" />;
}

export function TaskStatusPill({ status }: { status: TaskStatus }) {
  const s = TASK_STATUS[status];
  return (
    <span className={`pill tone-${s.tone}`}>
      <TaskStatusIcon status={status} size={11} />
      {s.label}
    </span>
  );
}

export function toneVar(t: Tone): string {
  return { good: 'good', warning: 'warn', critical: 'crit', info: 'info', neutral: 'neutral', accent: 'accent' }[t];
}

export const PLATFORM: Record<PlatformKind, { label: string; icon: LucideIcon }> = {
  telegram: { label: 'Telegram', icon: Send },
  discord: { label: 'Discord', icon: MessagesSquare },
  slack: { label: 'Slack', icon: Hash },
  cli: { label: 'CLI', icon: Terminal },
  api: { label: 'API', icon: Plug },
  mobile: { label: 'Mobile', icon: Smartphone },
  kanban: { label: 'Kanban', icon: SquareKanban },
};

export function PlatformChip({ kind, connected = true }: { kind: PlatformKind; connected?: boolean }) {
  const p = PLATFORM[kind];
  const Icon = p.icon;
  return (
    <span className="chip" title={connected ? `${p.label} 已连接` : `${p.label} 未连接`} style={connected ? undefined : { textDecoration: 'line-through' }}>
      <Icon size={11} />
      {p.label}
    </span>
  );
}

const PRIO: Record<KanbanTask['priority'], { label: string; tone: ActivityTone }> = {
  3: { label: '紧急', tone: 'critical' },
  2: { label: '高', tone: 'warning' },
  1: { label: '中', tone: 'neutral' },
  0: { label: '低', tone: 'neutral' },
};

export function Priority({ p }: { p: KanbanTask['priority'] }) {
  if (p < 2) return null;
  const x = PRIO[p];
  return <span className={`prio tone-${x.tone}`}>{x.label}</span>;
}

export const priorityLabel = (p: KanbanTask['priority']) => PRIO[p].label;
