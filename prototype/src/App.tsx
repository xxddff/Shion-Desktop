import { useCallback, useEffect, useMemo, useState } from 'react';
import { ConnectionPopover, MenuBar, QuickAsk, Toasts } from './components/Overlays';
import { NavContext, Sidebar } from './components/Shell';
import { startSimulator } from './data/simulator';
import { useAppState } from './data/store';
import { parseHash } from './route';
import { BoardView } from './views/Board';
import { CalendarView } from './views/Calendar';
import { ChatView } from './views/Chat';
import { DesktopView } from './views/Desktop';
import { Confirm, Reports } from './views/Reports';
import { Today } from './views/Today';
import { Todos } from './views/Todos';

type Theme = 'system' | 'light' | 'dark';

function readTheme(): Theme {
  try {
    const t = localStorage.getItem('shion.theme');
    return t === 'light' || t === 'dark' ? t : 'system';
  } catch {
    return 'system';
  }
}

export function App() {
  const state = useAppState();
  const [hash, setHash] = useState(() => location.hash);
  const [quick, setQuick] = useState(false);
  const [conn, setConn] = useState(false);
  const [nav, setNav] = useState(false);
  const [theme, setTheme] = useState<Theme>(readTheme);
  const route = useMemo(() => parseHash(hash), [hash]);

  useEffect(() => startSimulator(), []);

  useEffect(() => {
    const on = () => {
      setHash(location.hash);
      setNav(false);
    };
    window.addEventListener('hashchange', on);
    return () => window.removeEventListener('hashchange', on);
  }, []);

  useEffect(() => {
    const root = document.documentElement;
    if (theme === 'system') root.removeAttribute('data-theme');
    else root.setAttribute('data-theme', theme);
    try {
      localStorage.setItem('shion.theme', theme);
    } catch {
      /* storage unavailable: the theme still applies for this visit */
    }
  }, [theme]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') {
        e.preventDefault();
        setQuick((x) => !x);
      } else if (e.altKey && e.code === 'Space') {
        e.preventDefault();
        setQuick(true);
      } else if (e.key === 'Escape') {
        setQuick(false);
        setConn(false);
        setNav(false);
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);

  const openNav = useCallback(() => setNav(true), []);
  const openQuick = useCallback(() => setQuick(true), []);

  return (
    <NavContext.Provider value={{ openNav }}>
      <div className="desk">
        <MenuBar state={state} onQuickAsk={openQuick} />
        <div className="window-wrap">
          <div className={`window${nav ? ' nav-open' : ''}`}>
            <Sidebar state={state} route={route} onQuickAsk={openQuick} onConnection={() => setConn((x) => !x)} />
            {nav && <div className="scrim" style={{ zIndex: 44 }} onClick={() => setNav(false)} />}
            <main className="main">
              {route.view === 'today' && <Today state={state} />}
              {route.view === 'todos' && <Todos state={state} />}
              {route.view === 'board' && <BoardView state={state} cardId={route.cardId} />}
              {route.view === 'work' && (
                <ChatView state={state} botId={state.cards.find((c) => c.id === route.cardId)?.assignee ?? ''} sessionKey={`w:${route.cardId}`} />
              )}
              {route.view === 'calendar' && <CalendarView state={state} />}
              {route.view === 'reports' && <Reports state={state} kind={route.kind} />}
              {route.view === 'confirm' && <Confirm state={state} />}
              {route.view === 'desktop' && <DesktopView state={state} botId={route.botId} />}
              {route.view === 'chat' && <ChatView state={state} botId={route.botId} />}
              <Toasts toasts={state.toasts} state={state} />
            </main>
            {quick && <QuickAsk state={state} onClose={() => setQuick(false)} />}
            {conn && <ConnectionPopover state={state} theme={theme} setTheme={setTheme} onClose={() => setConn(false)} />}
          </div>
        </div>
      </div>
    </NavContext.Provider>
  );
}
