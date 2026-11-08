import { ArrowRight, CalendarDays, CircleCheck, Flower2, Hand, Newspaper, Send, Sun, TrainFront, X } from 'lucide-react';
import { useEffect, useMemo, useRef, useState } from 'react';
import { dayDiff } from '../data/clock';
import type { AppState, Toast } from '../data/model';
import { dismissToast, sendMessage, setActivityLog, setSimulate } from '../data/store';
import { go } from '../route';
import { AreaDot, Avatar } from '../ui/bits';
import { hm, until, useNow, weekday } from '../ui/format';
import { TodoRow } from './Items';

// ------------------------------------------------------------ quick ask (⌘K)

interface Hit {
  label: string;
  hint?: string;
  icon: JSX.Element;
  hash: string;
}

const SUGGEST = ['明天几点出门？', '把实验报告挪到明天下午', '帮我核实一下这条新闻是不是真的', '今晚提醒我交房租'];

export function QuickAsk({ state, onClose }: { state: AppState; onClose: () => void }) {
  const [q, setQ] = useState('');
  const [sel, setSel] = useState(-1);
  const chief = state.bots.find((b) => b.chief)!;
  const hits = useMemo<Hit[]>(() => {
    const k = q.trim().toLowerCase();
    if (!k) return [];
    const pages: Hit[] = [
      { label: '今天', icon: <Sun size={15} />, hash: 'today' },
      { label: '待办', icon: <CircleCheck size={15} />, hash: 'todos' },
      { label: '日程', icon: <CalendarDays size={15} />, hash: 'calendar' },
      { label: '日报', icon: <Newspaper size={15} />, hash: 'reports' },
      { label: '等你确认', icon: <Hand size={15} />, hash: 'confirm' },
    ];
    const bots = state.bots.map((b) => ({ label: b.name, hint: b.title, icon: <Avatar bot={b} size={18} />, hash: `chat-${b.id}` }));
    const todos = state.todos.filter((t) => !t.done).map((t) => ({ label: t.title, hint: '待办', icon: <AreaDot area={t.area} />, hash: 'todos' }));
    return [...pages, ...bots, ...todos].filter((h) => `${h.label} ${h.hint ?? ''}`.toLowerCase().includes(k)).slice(0, 6);
  }, [q, state.bots, state.todos]);

  const send = (text: string) => {
    sendMessage(chief.id, text);
    onClose();
    go(`chat-${chief.id}`);
  };

  return (
    <>
      <div className="scrim" onClick={onClose} />
      <div className="quick" role="dialog" aria-label="跟紫苑说">
        <form
          className="quick-input"
          onSubmit={(e) => {
            e.preventDefault();
            if (sel >= 0 && hits[sel]) {
              go(hits[sel].hash);
              onClose();
            } else if (q.trim()) send(q.trim());
          }}
        >
          <Avatar bot={chief} size={26} />
          <input
            id="quick-input"
            autoFocus
            value={q}
            onChange={(e) => {
              setQ(e.target.value);
              setSel(-1);
            }}
            onKeyDown={(e) => {
              if (e.key === 'ArrowDown') {
                e.preventDefault();
                setSel((x) => Math.min(hits.length - 1, x + 1));
              } else if (e.key === 'ArrowUp') {
                e.preventDefault();
                setSel((x) => Math.max(-1, x - 1));
              } else if (e.key === 'Escape') onClose();
            }}
            placeholder="跟紫苑说点什么，或者搜索…"
          />
          <kbd>↩ 发送</kbd>
        </form>
        <ul>
          {hits.length === 0 && (
            <>
              <li className="grp">可以这样说</li>
              {SUGGEST.map((s) => (
                <li key={s}>
                  <button onClick={() => send(s)}>
                    <Send size={14} />
                    {s}
                  </button>
                </li>
              ))}
            </>
          )}
          {hits.length > 0 && <li className="grp">跳转到</li>}
          {hits.map((h, i) => (
            <li key={`${h.hash}-${h.label}`}>
              <button
                aria-selected={i === sel}
                onMouseEnter={() => setSel(i)}
                onClick={() => {
                  go(h.hash);
                  onClose();
                }}
              >
                {h.icon}
                <span className="grow">{h.label}</span>
                {h.hint && <span className="faint">{h.hint}</span>}
              </button>
            </li>
          ))}
        </ul>
        <div className="quick-foot faint">在 Mac 上任何地方按 ⌥Space 都能叫出这个框</div>
      </div>
    </>
  );
}

// ------------------------------------------------------------ connection

type Theme = 'system' | 'light' | 'dark';

export function ConnectionPopover({ state, theme, setTheme, onClose }: { state: AppState; theme: Theme; setTheme: (t: Theme) => void; onClose: () => void }) {
  const c = state.connection;
  return (
    <>
      <div className="scrim clear" onClick={onClose} />
      <div className="popover" role="dialog" aria-label="连接">
        <div className="section-title">Hermes 在哪里</div>
        <div className="conn-row">
          <span className="dot good" />
          <div>
            <div>{c.name}（VPS）</div>
            <div className="faint mono">{c.host}</div>
            <div className="faint">
              远程网关 · 经 {c.kind === 'tailscale' ? 'Tailscale' : c.kind === 'https' ? 'HTTPS' : 'SSH 隧道'} · {c.auth}登录
            </div>
          </div>
        </div>
        <div className="conn-row off">
          <span className="dot" />
          <div>
            <div>这台 Mac</div>
            <div className="faint">以后接入：让助手在本机打开应用、读文件、用提醒事项</div>
          </div>
        </div>
        <label className="switch" htmlFor="activity-toggle">
          <span>
            记录应用使用情况
            <span className="faint block">只记应用名和时长，用来写每日回顾</span>
          </span>
          <input id="activity-toggle" type="checkbox" checked={c.activityLog} onChange={(e) => setActivityLog(e.target.checked)} />
        </label>
        <label className="switch" htmlFor="sim-toggle">
          <span>示例数据实时播放</span>
          <input id="sim-toggle" type="checkbox" checked={state.simulate} onChange={(e) => setSimulate(e.target.checked)} />
        </label>
        <div className="switch">
          <span>外观</span>
          <div className="segmented" role="group" aria-label="外观">
            {(['system', 'light', 'dark'] as Theme[]).map((t) => (
              <button key={t} aria-pressed={theme === t} onClick={() => setTheme(t)}>
                {{ system: '跟随系统', light: '浅色', dark: '深色' }[t]}
              </button>
            ))}
          </div>
        </div>
      </div>
    </>
  );
}

// ------------------------------------------------------------ toasts (system notifications)

export function Toasts({ toasts, state }: { toasts: Toast[]; state: AppState }) {
  useEffect(() => {
    if (!toasts.length) return;
    const id = window.setTimeout(() => dismissToast(toasts[0].id), 7000);
    return () => window.clearTimeout(id);
  }, [toasts]);
  return (
    <div className="toasts" aria-live="polite">
      {toasts.map((t) => {
        const bot = state.bots.find((b) => b.id === t.botId);
        return (
          <a key={t.id} className="toast" href={t.href} onClick={() => dismissToast(t.id)}>
            <Avatar bot={bot} size={30} />
            <span>
              <div className="t">{t.title}</div>
              {t.body && <div className="b">{t.body}</div>}
            </span>
            <button
              className="btn ghost icon"
              style={{ width: 20, height: 20 }}
              aria-label="关闭"
              onClick={(e) => {
                e.preventDefault();
                e.stopPropagation();
                dismissToast(t.id);
              }}
            >
              <X size={12} />
            </button>
          </a>
        );
      })}
    </div>
  );
}

// ------------------------------------------------------------ menu bar extra

/** A stand-in for the macOS menu bar so the MenuBarExtra can be judged in a browser. */
export function MenuBar({ state, onQuickAsk }: { state: AppState; onQuickAsk: () => void }) {
  const now = useNow(1000);
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  // backdrop-filter on the bar traps fixed children, so close on outside clicks from the document instead of a scrim
  useEffect(() => {
    if (!open) return;
    const down = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false);
    };
    const key = (e: KeyboardEvent) => e.key === 'Escape' && setOpen(false);
    document.addEventListener('mousedown', down);
    document.addEventListener('keydown', key);
    return () => {
      document.removeEventListener('mousedown', down);
      document.removeEventListener('keydown', key);
    };
  }, [open]);
  const next = state.events.filter((e) => dayDiff(e.start, now) === 0 && e.start > now && e.kind !== 'commute')[0];
  const top = state.todos
    .filter((t) => !t.done && ((t.doAt && dayDiff(t.doAt, now) <= 0) || (t.dueAt && dayDiff(t.dueAt, now) <= 0)))
    .sort((a, b) => (a.dueAt ?? a.doAt ?? Infinity) - (b.dueAt ?? b.doAt ?? Infinity))
    .slice(0, 3);
  const c = state.commute;
  return (
    <div className="menubar" ref={ref}>
      <div className="mb-inner">
        <b>Shion</b>
        <span className="mb-menu hide-narrow">文件</span>
        <span className="mb-menu hide-narrow">编辑</span>
        <span className="mb-menu hide-narrow">显示</span>
        <span className="mb-menu hide-narrow">窗口</span>
        <span className="grow" />
        <button className={`mb-item${open ? ' on' : ''}`} onClick={() => setOpen((x) => !x)} aria-expanded={open} aria-label="Shion 菜单栏">
          <Flower2 size={13} />
          {next ? (
            <span className="num">
              {hm(next.start)} {next.title.replace(/ 第\d+回/, '')}
            </span>
          ) : (
            <span>今天没有日程了</span>
          )}
          {state.asks.length > 0 && <span className="mb-badge">{state.asks.length}</span>}
        </button>
        <span className="num mb-clock">
          {weekday(now)} {hm(now)}
        </span>
      </div>
      {open && (
        <>
          <div className="mb-pop" role="dialog" aria-label="Shion">
            {next && (
              <div className="mbp-next">
                <span className="faint">下一件 · {until(next.start, now)}</span>
                <strong>{next.title}</strong>
                <span className="muted">
                  {hm(next.start)}–{hm(next.end)} · {next.place}
                </span>
              </div>
            )}
            <div className="mbp-row">
              <TrainFront size={14} />
              <span>
                回程 {hm(c.leaveAt)} · {c.route.join(' → ')}
              </span>
              <span className={`pill ${c.status === 'normal' ? 'tone-good' : 'tone-warning'}`}>{c.status === 'normal' ? '正常' : '延误'}</span>
            </div>
            <div className="mbp-todos">
              {top.map((t) => (
                <TodoRow key={t.id} t={t} now={now} />
              ))}
            </div>
            {state.asks.length > 0 && (
              <a
                className="mbp-row link"
                href="#confirm"
                onClick={() => setOpen(false)}
              >
                <Hand size={14} />
                <span>{state.asks.length} 件事等你确认</span>
                <ArrowRight size={12} />
              </a>
            )}
            <button
              className="mbp-ask"
              onClick={() => {
                setOpen(false);
                onQuickAsk();
              }}
            >
              跟紫苑说… <kbd>⌥Space</kbd>
            </button>
          </div>
        </>
      )}
    </div>
  );
}
