import { ArrowRight, CalendarDays, CircleCheck, Hand, Monitor, Newspaper, Search, SquareKanban, Sun, TrainFront, X } from 'lucide-react';
import { useEffect, useMemo, useRef, useState } from 'react';
import { dayDiff } from '../data/clock';
import type { AppState, Toast } from '../data/model';
import { dismissToast, sendMessage, setActivityLog, setFocusEnabled, setSimulate } from '../data/store';
import { FocusRow } from './Focus';
import { go } from '../route';
import { AreaDot, Avatar, Mark } from '../ui/bits';
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
      { label: '等你确认', icon: <Hand size={15} />, hash: 'confirm' },
      { label: '待办', icon: <CircleCheck size={15} />, hash: 'todos' },
      { label: '日程', icon: <CalendarDays size={15} />, hash: 'calendar' },
      { label: '日报', icon: <Newspaper size={15} />, hash: 'reports' },
      { label: '看板', icon: <SquareKanban size={15} />, hash: 'board' },
      { label: '云桌面', icon: <Monitor size={15} />, hash: 'desktop' },
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
      <div className="quick" role="dialog" aria-label="跟詩音说">
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
          <Mark size={26} />
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
            placeholder="跟詩音说点什么，或者搜索"
            aria-label="跟詩音说点什么，或者搜索"
          />
        </form>
        <ul className="quick-list">
          {hits.length === 0 && (
            <>
              <li className="quick-group">可以这样说</li>
              {SUGGEST.map((s) => (
                <li key={s}>
                  <button onClick={() => send(s)}>{s}</button>
                </li>
              ))}
            </>
          )}
          {hits.length > 0 && (
            <>
              <li className="quick-group">
                <Search size={11} /> 跳转
              </li>
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
                    {h.hint && <span className="quiet">{h.hint}</span>}
                  </button>
                </li>
              ))}
              <li className="quick-group">按 ↩ 把这句话交给詩音</li>
            </>
          )}
        </ul>
        <p className="quick-foot">在 Mac 上任何地方按 ⌥Space 都能叫出这里</p>
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
      <div className="popover" role="dialog" aria-label="连接与设置">
        <section>
          <h4>Hermes</h4>
          <div className="pop-row">
            <span className={`conn-dot ${c.state}`} />
            <div className="grow">
              <div>{c.name}</div>
              <div className="quiet small">
                {c.kind === 'cloudflare' ? 'Cloudflare Tunnel · Access' : c.kind === 'tailscale' ? 'Tailscale' : 'SSH 隧道'} · {c.auth} · {c.latencyMs} ms
              </div>
            </div>
          </div>
          <div className="pop-row off">
            <span className="conn-dot offline" />
            <div className="grow">
              <div>这台 Mac</div>
              <div className="quiet small">以后接入：让助手在本机打开应用、读文件、用提醒事项</div>
            </div>
          </div>
        </section>
        <section>
          <label className="pop-switch" htmlFor="activity-toggle">
            <span className="grow">
              记录应用使用情况
              <span className="quiet small block">只记应用名和时长，用来写每日回顾</span>
            </span>
            <input id="activity-toggle" type="checkbox" checked={c.activityLog} onChange={(e) => setActivityLog(e.target.checked)} />
          </label>
          <label className="pop-switch" htmlFor="focus-toggle">
            <span className="grow">
              专注检查
              <span className="quiet small block">在本机判断你在做的是不是计划里的事，只把结论告诉詩音。要读窗口标题，需要辅助功能权限</span>
            </span>
            <input id="focus-toggle" type="checkbox" checked={state.focus.enabled} onChange={(e) => setFocusEnabled(e.target.checked)} />
          </label>
          <label className="pop-switch" htmlFor="sim-toggle">
            <span className="grow">示例数据自动播放</span>
            <input id="sim-toggle" type="checkbox" checked={state.simulate} onChange={(e) => setSimulate(e.target.checked)} />
          </label>
          <div className="pop-switch">
            <span className="grow">外观</span>
            <div className="seg sm" role="group" aria-label="外观">
              {(['system', 'light', 'dark'] as Theme[]).map((t) => (
                <button key={t} aria-pressed={theme === t} onClick={() => setTheme(t)}>
                  {{ system: '自动', light: '浅色', dark: '深色' }[t]}
                </button>
              ))}
            </div>
          </div>
        </section>
      </div>
    </>
  );
}

// ------------------------------------------------------------ notifications

/** Stand-ins for macOS notifications: at most two at a time, newest on top, each gone after a few seconds. */
export function Toasts({ toasts, state }: { toasts: Toast[]; state: AppState }) {
  const shown = [...toasts].reverse();
  useEffect(() => {
    if (!toasts.length) return;
    const id = window.setTimeout(() => dismissToast(toasts[0].id), 6000);
    return () => window.clearTimeout(id);
  }, [toasts]);
  return (
    <div className="toasts" aria-live="polite">
      {shown.map((t) => {
        const bot = state.bots.find((b) => b.id === t.botId);
        return (
          <a key={t.id} className="toast" href={t.href} onClick={() => dismissToast(t.id)}>
            <Avatar bot={bot} size={28} />
            <span className="toast-main">
              <span className="toast-title">{t.title}</span>
              {t.body && <span className="toast-body">{t.body}</span>}
            </span>
            <button
              className="icon-btn sm"
              aria-label="关闭"
              onClick={(e) => {
                e.preventDefault();
                e.stopPropagation();
                dismissToast(t.id);
              }}
            >
              <X size={13} />
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
    .filter((t) => !t.done && !t.proposed && ((t.doAt && dayDiff(t.doAt, now) <= 0) || (t.dueAt && dayDiff(t.dueAt, now) <= 0)))
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
          <Mark size={15} mono />
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
        <div className="mb-pop" role="dialog" aria-label="Shion">
          <FocusRow state={state} now={now} />
          {next && (
            <div className="mbp-next">
              <span className="quiet small">下一件 · {until(next.start, now)}</span>
              <strong>{next.title}</strong>
              <span className="quiet">
                {hm(next.start)}–{hm(next.end)} · {next.place}
              </span>
            </div>
          )}
          <div className="mbp-row">
            <TrainFront size={14} />
            <span className="grow">
              回程 {hm(c.leaveAt)} · {c.route.join(' → ')}
            </span>
            <span className={c.status === 'normal' ? 'ok' : 'warm'}>{c.status === 'normal' ? '正常' : '延误'}</span>
          </div>
          <div className="mbp-todos">
            {top.map((t) => (
              <TodoRow key={t.id} t={t} now={now} withDay={false} />
            ))}
          </div>
          {state.asks.length > 0 && (
            <a className="mbp-row link" href="#confirm" onClick={() => setOpen(false)}>
              <Hand size={14} />
              <span className="grow">{state.asks.length} 件事等你确认</span>
              <ArrowRight size={13} />
            </a>
          )}
          <button
            className="mbp-ask"
            onClick={() => {
              setOpen(false);
              onQuickAsk();
            }}
          >
            <Mark size={18} />
            <span className="grow">跟詩音说…</span>
            <kbd>⌥Space</kbd>
          </button>
        </div>
      )}
    </div>
  );
}
