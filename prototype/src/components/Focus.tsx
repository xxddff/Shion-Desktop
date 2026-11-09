import { ChevronDown, Laptop, Target } from 'lucide-react';
import { useState } from 'react';
import { DEMO_WINDOWS, KIND_LABEL, focusNow } from '../data/focus';
import type { AppState, FocusSample } from '../data/model';
import { frontWindow, pauseFocus, resumeFocus } from '../data/store';
import { hm } from '../ui/format';

/** A window's line in the local log: what it was against the plan. */
function fitLabel(s: FocusSample): { text: string; tone: string } {
  switch (s.fit) {
    case 'same':
      return { text: '就是这件事', tone: 'ok' };
    case 'related':
      return { text: `相关 · ${KIND_LABEL[s.kind]}`, tone: 'ok' };
    case 'unrelated':
      return { text: KIND_LABEL[s.kind], tone: 'warm' };
    case 'away':
      return { text: '离开', tone: 'quiet' };
    default:
      return { text: KIND_LABEL[s.kind], tone: 'quiet' };
  }
}

/**
 * The focus check in the menu bar: is what is in front on this Mac what you
 * planned to be doing now? The on-device model judges each window; 詩音 only
 * hears the verdict, so window titles never leave the Mac.
 */
export function FocusRow({ state, now }: { state: AppState; now: number }) {
  const [open, setOpen] = useState(false);
  const f = state.focus;
  const v = focusNow(state, now);
  if (v.state === 'disabled') return null;
  const plan = f.target ? `「${f.target.title}」` : '';
  const text = {
    on: `在做${plan}`,
    off: `${plan}原定 ${f.target ? hm(f.target.from) : ''}`,
    away: `${plan} · 你不在 Mac 前`,
    free: '现在没有安排，不用检查',
    paused: `专注检查暂停到 ${f.pausedUntil ? hm(f.pausedUntil) : ''}`,
  }[v.state];
  return (
    <div className={`mbp-focus${open ? ' open' : ''}`}>
      <button className="mbp-row mbp-btn" onClick={() => setOpen((x) => !x)} aria-expanded={open}>
        <Target size={14} />
        <span className="grow">{text}</span>
        {v.state === 'off' && <span className="warm">{v.minutes} 分钟没在做</span>}
        {v.state === 'on' && <span className="ok">对得上</span>}
        <ChevronDown size={13} className="mbp-chev" />
      </button>
      {open && (
        <div className="focus-detail">
          <ol className="focus-log" aria-label="这台 Mac 上的前台窗口">
            {f.samples.slice(-4).map((s) => {
              const fit = fitLabel(s);
              return (
                <li key={s.at}>
                  <span className="num">{hm(s.at)}</span>
                  <span className="focus-win" title={s.title}>
                    <b>{s.app}</b> {s.title}
                  </span>
                  <span className={`focus-fit ${fit.tone}`}>{fit.text}</span>
                </li>
              );
            })}
          </ol>
          <p className="focus-note">
            <Laptop size={12} />
            <span>窗口标题只留在这台 Mac 上。{f.sent ? `詩音收到的只有：${f.sent.text}` : '还没有告诉詩音什么。'}</span>
          </p>
          <div className="focus-actions">
            {v.state === 'paused' ? (
              <button className="btn sm" onClick={resumeFocus}>
                恢复
              </button>
            ) : (
              <button className="btn sm" onClick={() => pauseFocus(60)}>
                暂停 1 小时
              </button>
            )}
          </div>
          <label className="focus-demo">
            <span>原型演示：换一个前台窗口</span>
            <select
              value=""
              onChange={(e) => {
                if (e.target.value !== '') frontWindow(Number(e.target.value));
              }}
            >
              <option value="">选一个…</option>
              {DEMO_WINDOWS.map((w, i) => (
                <option key={w.app + w.title} value={i}>
                  {w.title ? `${w.app} · ${w.title}` : w.app}
                </option>
              ))}
            </select>
          </label>
        </div>
      )}
    </div>
  );
}
