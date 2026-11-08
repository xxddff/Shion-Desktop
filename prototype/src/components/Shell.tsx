import { CalendarDays, CircleCheck, Flower2, Hand, Menu, Monitor, Newspaper, SquareKanban, Sun, type LucideIcon } from 'lucide-react';
import { createContext, useContext, type ReactNode } from 'react';
import { dayDiff, demoNow } from '../data/clock';
import type { AppState } from '../data/model';
import type { Route } from '../route';
import { Avatar, Busy, botMood } from '../ui/bits';

export const NavContext = createContext<{ openNav: () => void; openQuick: () => void }>({ openNav: () => {}, openQuick: () => {} });

/** The one door to the secretary from any page: opens the ⌘K panel. */
export function AskButton() {
  const { openQuick } = useContext(NavContext);
  return (
    <button className="ask-btn" onClick={openQuick}>
      <Flower2 size={14} />
      <span className="hide-narrow">跟紫苑说</span>
      <kbd className="hide-narrow">⌘K</kbd>
    </button>
  );
}

export function Toolbar({
  title,
  sub,
  children,
  ask = true,
  hideTitle = false,
}: {
  title: ReactNode;
  sub?: ReactNode;
  children?: ReactNode;
  ask?: boolean;
  /** For pages that already say who they are in large type (今天). */
  hideTitle?: boolean;
}) {
  const { openNav } = useContext(NavContext);
  return (
    <header className={`toolbar${hideTitle ? ' bare' : ''}`}>
      <button className="icon-btn menu-btn" onClick={openNav} aria-label="打开侧边栏">
        <Menu size={16} />
      </button>
      <div className="tb-titles">
        <h1 className={hideTitle ? 'sr-only' : undefined}>{title}</h1>
        {sub && <p>{sub}</p>}
      </div>
      <div className="tb-actions">
        {children}
        {ask && <AskButton />}
      </div>
    </header>
  );
}

function Item({ href, icon: Icon, label, current, trail }: { href: string; icon: LucideIcon; label: string; current: boolean; trail?: ReactNode }) {
  return (
    <a className="sb-item" href={href} aria-current={current ? 'page' : undefined}>
      <Icon size={16} strokeWidth={1.9} />
      <span className="sb-label">{label}</span>
      {trail}
    </a>
  );
}

export function Sidebar({ state, route, onConnection }: { state: AppState; route: Route; onConnection: () => void }) {
  const now = demoNow();
  const today = state.todos.filter((t) => !t.done && ((t.doAt && dayDiff(t.doAt, now) <= 0) || (t.dueAt && dayDiff(t.dueAt, now) <= 0))).length;
  const is = (v: Route['view']) => route.view === v;
  const c = state.connection;
  const team = [...state.bots].sort((a, b) => Number(!!b.chief) - Number(!!a.chief));
  const workBot = route.view === 'work' ? state.cards.find((x) => x.id === route.cardId)?.assignee : undefined;

  return (
    <nav className="sidebar" aria-label="导航">
      <div className="sb-head">
        <div className="traffic" aria-hidden="true">
          <i />
          <i />
          <i />
        </div>
      </div>
      <div className="sb-scroll">
        <Item href="#today" icon={Sun} label="今天" current={is('today')} />
        <Item
          href="#confirm"
          icon={Hand}
          label="等你确认"
          current={is('confirm')}
          trail={state.asks.length > 0 && <span className="sb-badge">{state.asks.length}</span>}
        />
        <Item href="#todos" icon={CircleCheck} label="待办" current={is('todos')} trail={today > 0 && <span className="sb-count">{today}</span>} />
        <Item href="#calendar" icon={CalendarDays} label="日程" current={is('calendar')} />
        <Item href="#reports" icon={Newspaper} label="日报" current={is('reports')} />

        <div className="sb-group">工作区</div>
        <Item href="#board" icon={SquareKanban} label="看板" current={is('board')} />
        <Item href="#desktop" icon={Monitor} label="云桌面" current={is('desktop')} />

        <div className="sb-group">助手</div>
        {team.map((b) => {
          const mood = botMood(b, state.asks.some((a) => a.botId === b.id));
          const current = (route.view === 'chat' && route.botId === b.id) || (route.view === 'work' && workBot === b.id);
          return (
            <a key={b.id} className="sb-item sb-bot" href={`#chat-${b.id}`} aria-current={current ? 'page' : undefined}>
              <Avatar bot={b} size={22} />
              <span className="sb-label">
                {b.name}
                {b.chief && <span className="sb-role">总秘书</span>}
              </span>
              {mood === 'busy' && <Busy />}
              {mood === 'warm' && <span className="sb-dot" title="等你" />}
            </a>
          );
        })}
      </div>
      <button className="sb-foot" onClick={onConnection}>
        <span className={`conn-dot ${c.state}`} />
        <span className="sb-label">{c.name}</span>
        <span className="sb-note">示例数据</span>
      </button>
    </nav>
  );
}
