import { CircleSlash, LoaderCircle, Moon, Circle, type LucideIcon } from 'lucide-react';
import type { CSSProperties } from 'react';
import type { Area, Bot, BotStatus } from '../data/model';

export function Avatar({ bot, size = 22, showStatus = false }: { bot?: Bot; size?: number; showStatus?: boolean }) {
  const c = bot ? (bot.hue === 'accent' ? 'var(--accent)' : `var(--id-${bot.hue})`) : undefined;
  const style = { '--size': `${size}px`, ...(c ? { '--c': c } : {}) } as CSSProperties;
  return (
    <span className={`avatar${bot ? '' : ' you'}${bot?.chief ? ' chief' : ''}`} style={style} aria-hidden="true">
      {bot ? bot.name[0] : '你'}
      {bot && showStatus && <span className={`status dot ${BOT_STATUS[bot.status].tone}`} />}
    </span>
  );
}

export const BOT_STATUS: Record<BotStatus, { label: string; tone: string; icon: LucideIcon }> = {
  working: { label: '在忙', tone: 'info', icon: LoaderCircle },
  online: { label: '在线', tone: 'good', icon: Circle },
  idle: { label: '待命', tone: 'neutral', icon: Moon },
  blocked: { label: '等你', tone: 'warning', icon: CircleSlash },
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

export const AREA: Record<Area | 'other', { label: string; slot: string }> = {
  study: { label: '学习', slot: 'var(--id-0)' },
  work: { label: '工作', slot: 'var(--id-1)' },
  life: { label: '生活', slot: 'var(--id-2)' },
  other: { label: '其他', slot: 'var(--neutral)' },
};

export function AreaDot({ area }: { area: Area | 'other' }) {
  return <span className="area-dot" style={{ background: AREA[area].slot }} aria-hidden="true" />;
}

export function AreaChip({ area }: { area: Area | 'other' }) {
  return (
    <span className="chip">
      <AreaDot area={area} />
      {AREA[area].label}
    </span>
  );
}
