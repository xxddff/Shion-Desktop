import { CalendarDays, CircleCheck, Hand, Menu, Newspaper, Search, Sun } from 'lucide-react';
import { createContext, useContext, type ReactNode } from 'react';
import { demoNow } from '../data/clock';
import type { AppState } from '../data/model';
import type { Route } from '../route';
import { Avatar } from '../ui/bits';
import { dayDiff } from '../data/clock';

export const NavContext = createContext<{ openNav: () => void }>({ openNav: () => {} });

export function Toolbar({ title, sub, children }: { title: ReactNode; sub?: ReactNode; children?: ReactNode }) {
  const { openNav } = useContext(NavContext);
  return (
    <header className="toolbar">
      <button className="btn ghost icon menu-btn" onClick={openNav} aria-label="打开侧边栏">
        <Menu size={16} />
      </button>
      <div className="titles">
        <h1>{title}</h1>
        {sub && <span className="sub">{sub}</span>}
      </div>
      {children}
    </header>
  );
}

interface SidebarProps {
  state: AppState;
  route: Route;
  onQuickAsk: () => void;
  onConnection: () => void;
}

export function Sidebar({ state, route, onQuickAsk, onConnection }: SidebarProps) {
  const now = demoNow();
  const todayTodos = state.todos.filter((t) => !t.done && ((t.doAt && dayDiff(t.doAt, now) <= 0) || (t.dueAt && dayDiff(t.dueAt, now) <= 0))).length;
  const current = (v: string, id?: string) =>
    route.view === v && (id === undefined || (route.view === 'chat' && route.botId === id)) ? 'page' : undefined;
  const chief = state.bots.find((b) => b.chief)!;
  const team = state.bots.filter((b) => !b.chief);
  const asksFor = (id: string) => state.asks.filter((a) => a.botId === id).length;
  const c = state.connection;

  return (
    <nav className="sidebar" aria-label="导航">
      <div className="sidebar-head">
        <div className="traffic" aria-hidden="true">
          <i />
          <i />
          <i />
        </div>
      </div>
      <div className="sidebar-scroll">
        <button className="search-btn" onClick={onQuickAsk}>
          <Search size={13} />
          跟紫苑说，或搜索…
          <kbd>⌘K</kbd>
        </button>
        <a className="side-item" href="#today" aria-current={current('today')}>
          <Sun size={15} />
          <span className="label">今天</span>
        </a>
        <a className="side-item" href="#todos" aria-current={current('todos')}>
          <CircleCheck size={15} />
          <span className="label">待办</span>
          {todayTodos > 0 && <span className="count">{todayTodos}</span>}
        </a>
        <a className="side-item" href="#calendar" aria-current={current('calendar')}>
          <CalendarDays size={15} />
          <span className="label">日程</span>
        </a>
        <a className="side-item" href="#reports" aria-current={current('reports')}>
          <Newspaper size={15} />
          <span className="label">日报</span>
        </a>
        <a className="side-item" href="#confirm" aria-current={current('confirm')}>
          <Hand size={15} />
          <span className="label">等你确认</span>
          {state.asks.length > 0 && <span className="badge">{state.asks.length}</span>}
        </a>

        <div className="side-label">秘书</div>
        <a className="side-item tall" href={`#chat-${chief.id}`} aria-current={current('chat', chief.id)}>
          <Avatar bot={chief} size={26} showStatus />
          <span className="label stacked">
            <span>{chief.name}</span>
            <span className="note">{chief.statusNote}</span>
          </span>
        </a>

        <div className="side-label">助手</div>
        {team.map((b) => (
          <a key={b.id} className="side-item" href={`#chat-${b.id}`} aria-current={current('chat', b.id)}>
            <Avatar bot={b} size={20} showStatus />
            <span className="label">{b.name}</span>
            {asksFor(b.id) > 0 && <span className="dot warning" title="有事等你确认" />}
          </a>
        ))}
      </div>
      <div className="sidebar-foot">
        <button className="conn-btn" onClick={onConnection}>
          <span className={`dot ${c.state === 'connected' ? 'good' : c.state === 'reconnecting' ? 'warning' : 'critical'}`} />
          <span className="meta">
            <span>{c.state === 'connected' ? `已连接 ${c.name}` : '未连接'}</span>
            <span className="mono">
              SSH · {c.latencyMs}ms · 本机{c.localMac === 'on' ? '已接入' : '未接入'}
            </span>
          </span>
        </button>
      </div>
    </nav>
  );
}
