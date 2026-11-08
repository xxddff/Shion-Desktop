/**
 * The prototype runs on a demo clock: a weekday at 10:52, just after the
 * first class of the day, then advancing in real time. Seed data is laid
 * out relative to it so every screen opens on the same story.
 */
const loadedAt = Date.now();
const start = new Date();
// land on a weekday so the timetable makes sense
if (start.getDay() === 0) start.setDate(start.getDate() + 1);
if (start.getDay() === 6) start.setDate(start.getDate() + 2);
start.setHours(10, 52, 0, 0);

export const DEMO_START = start.getTime();
export const demoNow = () => DEMO_START + (Date.now() - loadedAt);

/** A wall-clock time on the demo day plus `day` days. */
export function at(day: number, h: number, m = 0): number {
  const d = new Date(DEMO_START);
  d.setDate(d.getDate() + day);
  d.setHours(h, m, 0, 0);
  return d.getTime();
}

export function startOfDay(t: number): number {
  const d = new Date(t);
  d.setHours(0, 0, 0, 0);
  return d.getTime();
}

/** Whole days between two instants, by calendar date. */
export function dayDiff(a: number, b: number): number {
  return Math.round((startOfDay(a) - startOfDay(b)) / 86_400_000);
}
