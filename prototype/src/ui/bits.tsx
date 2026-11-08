import type { CSSProperties } from 'react';
import type { Area, Bot } from '../data/model';

export const botColor = (bot?: Bot) => (bot ? (bot.hue === 'accent' ? 'var(--accent)' : `var(--id-${bot.hue})`) : 'var(--text-3)');

export function Avatar({ bot, size = 22 }: { bot?: Bot; size?: number }) {
  const style = { '--size': `${size}px`, '--c': botColor(bot) } as CSSProperties;
  return (
    <span className={`avatar${bot ? '' : ' you'}`} style={style} aria-hidden="true">
      {bot ? bot.name[0] : '你'}
    </span>
  );
}

/** Three dots that breathe while an assistant is working. */
export function Busy({ label = '在做' }: { label?: string }) {
  return (
    <span className="busy" role="img" aria-label={label}>
      <i />
      <i />
      <i />
    </span>
  );
}

/** How a bot is doing, in one of three registers: working, waiting on you, or quiet. */
export function botMood(bot: Bot, waitsOnYou: boolean): 'busy' | 'warm' | 'quiet' {
  if (waitsOnYou || bot.status === 'blocked') return 'warm';
  return bot.status === 'working' ? 'busy' : 'quiet';
}

export const AREA: Record<Area | 'other', { label: string; slot: string }> = {
  study: { label: '学习', slot: 'var(--id-0)' },
  work: { label: '工作', slot: 'var(--id-1)' },
  life: { label: '生活', slot: 'var(--id-2)' },
  other: { label: '其他', slot: 'var(--text-3)' },
};

export function AreaDot({ area }: { area: Area | 'other' }) {
  return <span className="area-dot" style={{ background: AREA[area].slot }} aria-hidden="true" />;
}
