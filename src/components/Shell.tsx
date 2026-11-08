import { Bot as BotIcon, Inbox, LayoutDashboard, Menu, Search, SquareKanban } from 'lucide-react';
import { createContext, useContext, type ReactNode } from 'react';
import type { AppState } from '../data/model';
import { Avatar } from '../ui/bits';
import type { Route } from '../route';

export const NavContext = createContext<{ openNav: () => void }>({ openNav: () => {} });

export function Toolbar({ title, sub, children }: { title: ReactNode; sub?: ReactNode; children?: ReactNode }) {
  const { openNav } = useContext(NavContext);
  return (
    <header className="toolbar" data-tauri-drag-region>
      <button className="btn ghost icon menu-btn" onClick={openNav} aria-label="打开侧边栏">
        <Menu size={16} />
      </button>
      <div className="titles" data-tauri-drag-region>
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
  onPalette: () => void;
  onConnection: () => void;
}

export function Sidebar({ state, route, onPalette, onConnection }: SidebarProps) {
  const cur = (r: Route) => (JSON.stringify(r) === JSON.stringify({ ...route, taskId: undefined }) ? 'page' : undefined);
  const running = (slug: string) => state.tasks.filter((t) => t.board === slug && t.status === 'running').length;
  const c = state.connection;
  return (
    <nav className="sidebar" aria-label="导航">
      <div className="sidebar-head" data-tauri-drag-region>
        <div className="traffic" aria-hidden="true">
          <i />
          <i />
          <i />
        </div>
      </div>
      <div className="sidebar-scroll">
        <button className="search-btn" onClick={onPalette}>
          <Search size={13} />
          搜索 Bot、任务…
          <kbd>⌘K</kbd>
        </button>
        <a className="side-item" href="#overview" aria-current={cur({ view: 'overview' })}>
          <LayoutDashboard size={15} />
          <span className="label">总览</span>
        </a>
        <a className="side-item" href="#inbox" aria-current={cur({ view: 'inbox' })}>
          <Inbox size={15} />
          <span className="label">待处理</span>
          {state.inbox.length > 0 && <span className="badge">{state.inbox.length}</span>}
        </a>

        <div className="side-label">Bots</div>
        <a className="side-item" href="#bots" aria-current={cur({ view: 'bots' })}>
          <BotIcon size={15} />
          <span className="label">全部 Bots</span>
          <span className="count">
            {state.bots.filter((b) => b.status !== 'offline').length}/{state.bots.length}
          </span>
        </a>
        {state.bots.map((b) => (
          <a key={b.id} className="side-item" href={`#bot-${b.id}`} aria-current={cur({ view: 'bot', id: b.id })}>
            <Avatar bot={b} size={18} showStatus />
            <span className="label">{b.displayName}</span>
            {state.inbox.some((r) => r.botId === b.id) && <span className="dot warning" title="有待你处理的请求" />}
          </a>
        ))}

        <div className="side-label">看板</div>
        {state.boards.map((bd) => (
          <a key={bd.slug} className="side-item" href={`#board-${bd.slug}`} aria-current={cur({ view: 'board', slug: bd.slug })}>
            <SquareKanban size={15} />
            <span className="label">{bd.name}</span>
            {running(bd.slug) > 0 && <span className="count">{running(bd.slug)} 运行中</span>}
          </a>
        ))}
      </div>
      <div className="sidebar-foot">
        <button className="conn-btn" onClick={onConnection}>
          <span className={`dot ${c.state === 'connected' ? 'good' : c.state === 'reconnecting' ? 'warning' : 'critical'}`} />
          <span className="meta">
            <span>{c.state === 'connected' ? '已连接 Hermes' : c.state === 'reconnecting' ? '重连中…' : '未连接'}</span>
            <span className="mono">
              {c.url.replace(/^wss?:\/\//, '').replace('/api/ws', '')} · {c.latencyMs}ms
            </span>
          </span>
        </button>
      </div>
    </nav>
  );
}
