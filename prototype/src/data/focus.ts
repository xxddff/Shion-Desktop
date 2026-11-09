import type { ActivityKind, AppState, FocusSample } from './model';

/** How 詩音 is told what kind of thing you were doing. */
export const KIND_LABEL: Record<ActivityKind, string> = {
  study: '学习',
  work: '工作',
  life: '生活',
  fun: '娱乐',
  social: '聊天',
  other: '其他',
};

/** Minutes off the plan before this Mac tells 詩音. */
export const OFF_REPORT_MIN = 5;

/**
 * Windows the prototype can pretend are in front, with what the on-device
 * model would say about each against the plan 「机器学习 课前小测」. The app
 * asks Foundation Models on the Mac instead.
 */
export const DEMO_WINDOWS: Omit<FocusSample, 'at'>[] = [
  { app: 'Safari', title: '機械学習基礎 第7回 課前小テスト - Moodle', kind: 'study', fit: 'same' },
  { app: 'Safari', title: '【機械学習】過学習と正則化をやさしく解説 - YouTube', kind: 'study', fit: 'related' },
  { app: 'Safari', title: '猫のおもしろ動画まとめ 2026 - YouTube', kind: 'fun', fit: 'unrelated' },
  { app: 'LINE', title: '研究室', kind: 'social', fit: 'unrelated' },
  { app: '锁屏', title: '', kind: 'other', fit: 'away' },
];

export type FocusVerdict =
  | { state: 'off'; minutes: number; since: number; kind: ActivityKind }
  | { state: 'on' | 'away' | 'free' | 'paused' | 'disabled' };

/** The verdict now, from the plan and the window in front. A plan whose todo is done is no plan. */
export function focusNow({ focus: f, todos }: Pick<AppState, 'focus' | 'todos'>, now: number): FocusVerdict {
  if (!f.enabled) return { state: 'disabled' };
  if (f.pausedUntil && f.pausedUntil > now) return { state: 'paused' };
  if (!f.target || now < f.target.from || todos.find((t) => t.id === f.target!.todoId)?.done) return { state: 'free' };
  const last = f.samples[f.samples.length - 1];
  if (!last || last.fit === 'away') return { state: 'away' };
  if (last.fit === 'same' || last.fit === 'related') return { state: 'on' };
  // off since the later of the planned start and when the current stretch of other things began
  let i = f.samples.length - 1;
  while (i > 0 && (f.samples[i - 1].fit === 'unrelated' || f.samples[i - 1].fit === 'none') && f.samples[i - 1].at >= f.target.from) i--;
  const since = Math.max(f.target.from, f.samples[i].at);
  return { state: 'off', minutes: Math.max(0, Math.floor((now - since) / 60_000)), since, kind: last.kind };
}
