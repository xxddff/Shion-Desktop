import { useEffect, useState } from 'react';
import { dayDiff, demoNow } from '../data/clock';

const WEEK = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];

export const hm = (t: number) => {
  const d = new Date(t);
  return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
};

export const md = (t: number) => {
  const d = new Date(t);
  return `${d.getMonth() + 1}月${d.getDate()}日`;
};

export const weekday = (t: number) => WEEK[new Date(t).getDay()];

/** 今天 / 明天 / 昨天 / 周三 / 11月20日 */
export function dayLabel(t: number, now: number): string {
  const n = dayDiff(t, now);
  if (n === 0) return '今天';
  if (n === 1) return '明天';
  if (n === 2) return '后天';
  if (n === -1) return '昨天';
  if (n > 2 && n < 7) return weekday(t);
  return md(t);
}

/** Day label plus time, dropping 23:59 and midnight which mean "end of day". */
export function when(t: number, now: number): string {
  const d = new Date(t);
  const allDay = (d.getHours() === 23 && d.getMinutes() === 59) || (d.getHours() === 0 && d.getMinutes() === 0);
  return allDay ? dayLabel(t, now) : `${dayLabel(t, now)} ${hm(t)}`;
}

export function ago(t: number, now: number): string {
  const s = Math.max(0, Math.round((now - t) / 1000));
  if (s < 45) return '刚刚';
  const m = Math.round(s / 60);
  if (m < 60) return `${m} 分钟前`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h} 小时前`;
  return dayLabel(t, now);
}

/** "还有 2 小时" / "超时 11 小时" */
export function until(t: number, now: number): string {
  const m = Math.round((t - now) / 60000);
  const abs = Math.abs(m);
  const txt = abs < 60 ? `${abs} 分钟` : abs < 1440 ? `${Math.round(abs / 60)} 小时` : `${Math.round(abs / 1440)} 天`;
  return m >= 0 ? `还有 ${txt}` : `超时 ${txt}`;
}

export function minutes(m: number): string {
  const h = Math.floor(m / 60);
  const r = m % 60;
  return h ? (r ? `${h} 小时 ${r} 分` : `${h} 小时`) : `${r} 分`;
}

/** The demo clock, refreshed on an interval. */
export function useNow(intervalMs = 1000): number {
  const [now, setNow] = useState(demoNow);
  useEffect(() => {
    const id = window.setInterval(() => setNow(demoNow()), intervalMs);
    return () => window.clearInterval(id);
  }, [intervalMs]);
  return now;
}
