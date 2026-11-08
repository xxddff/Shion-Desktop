import { Flag } from 'lucide-react';
import { at, dayDiff } from '../data/clock';
import type { AppState } from '../data/model';
import { Toolbar } from '../components/Shell';
import { AREA } from '../ui/bits';
import { hm, md, useNow, weekday } from '../ui/format';

const START_H = 8;
const END_H = 22;
const HOUR = 46;

export function CalendarView({ state }: { state: AppState }) {
  const now = useNow(30_000);
  const dow = (new Date(now).getDay() + 6) % 7; // Monday = 0
  const days = Array.from({ length: 7 }, (_, i) => at(i - dow, 0));
  const hours = Array.from({ length: END_H - START_H }, (_, i) => START_H + i);
  const nowTop = ((new Date(now).getHours() + new Date(now).getMinutes() / 60) - START_H) * HOUR;

  return (
    <>
      <Toolbar title="日程" sub={`${md(days[0])} – ${md(days[6])} · 课表、日程和排进去的待办`}>
        <div className="legend hide-narrow">
          {(['study', 'work', 'life'] as const).map((a) => (
            <span key={a}>
              <span className="area-dot" style={{ background: AREA[a].slot }} />
              {AREA[a].label}
            </span>
          ))}
        </div>
      </Toolbar>
      <div className="view">
        <div className="cal-scroll">
          <div className="cal">
            <div className="cal-head">
              <span />
              {days.map((d) => {
                const deadlines = state.todos.filter((t) => !t.done && t.dueAt && dayDiff(t.dueAt, d) === 0);
                return (
                  <div key={d} className={`cal-day-head${dayDiff(d, now) === 0 ? ' today' : ''}`}>
                    <span className="dn">
                      {weekday(d)} <b className="num">{new Date(d).getDate()}</b>
                    </span>
                    {deadlines.map((t) => (
                      <a key={t.id} className="deadline" href="#todos" title={`截止 ${hm(t.dueAt!)}`}>
                        <Flag size={10} />
                        {t.title}
                      </a>
                    ))}
                  </div>
                );
              })}
            </div>
            <div className="cal-body" style={{ height: hours.length * HOUR }}>
              <div className="cal-hours">
                {hours.map((h) => (
                  <span key={h} style={{ top: (h - START_H) * HOUR }} className="num">
                    {String(h).padStart(2, '0')}:00
                  </span>
                ))}
              </div>
              {days.map((d) => {
                const evs = state.events.filter((e) => dayDiff(e.start, d) === 0);
                const isToday = dayDiff(d, now) === 0;
                return (
                  <div key={d} className={`cal-col${isToday ? ' today' : ''}`}>
                    {hours.map((h) => (
                      <i key={h} className="cal-line" style={{ top: (h - START_H) * HOUR }} />
                    ))}
                    {evs.map((e) => {
                      const s = new Date(e.start);
                      const top = (s.getHours() + s.getMinutes() / 60 - START_H) * HOUR;
                      const height = Math.max(20, ((e.end - e.start) / 3_600_000) * HOUR - 2);
                      return (
                        <div
                          key={e.id}
                          className={`cal-ev kind-${e.kind}${e.end < now ? ' past' : ''}`}
                          style={{ top, height, ['--c' as string]: AREA[e.area].slot }}
                          title={`${e.title} ${hm(e.start)}–${hm(e.end)}${e.place ? ` · ${e.place}` : ''}`}
                        >
                          <span className="ce-t">{e.title}</span>
                          {height > 34 && (
                            <span className="ce-s num">
                              {hm(e.start)} {e.place ?? ''}
                            </span>
                          )}
                        </div>
                      );
                    })}
                    {isToday && nowTop > 0 && nowTop < hours.length * HOUR && <div className="cal-now" style={{ top: nowTop }} />}
                  </div>
                );
              })}
            </div>
          </div>
        </div>
      </div>
    </>
  );
}
