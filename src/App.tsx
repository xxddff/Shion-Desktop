import { useCallback, useEffect, useMemo, useState } from 'react';
import { ConnectionPopover, CommandPalette, NewTaskSheet, Toasts } from './components/Overlays';
import { NavContext, Sidebar } from './components/Shell';
import { startSimulator } from './data/simulator';
import { getState, seedHandshake, useAppState } from './data/store';
import { parseHash, type Route } from './route';
import { BoardView } from './views/Board';
import { BotDetail, BotsGrid } from './views/Bots';
import { InboxView } from './views/Inbox';
import { Overview } from './views/Overview';

type Theme = 'system' | 'light' | 'dark';

function readTheme(): Theme {
  try {
    const t = localStorage.getItem('shion.theme');
    return t === 'light' || t === 'dark' ? t : 'system';
  } catch {
    return 'system';
  }
}

const boardOf = (taskId: string) => getState().tasks.find((t) => t.id === taskId)?.board;

export function App() {
  const state = useAppState();
  const [hash, setHash] = useState(() => location.hash);
  const [palette, setPalette] = useState(false);
  const [newTask, setNewTask] = useState(false);
  const [conn, setConn] = useState(false);
  const [nav, setNav] = useState(false);
  const [theme, setThemeState] = useState<Theme>(readTheme);

  const route: Route = useMemo(() => parseHash(hash, boardOf), [hash]);

  useEffect(() => {
    seedHandshake();
    return startSimulator();
  }, []);

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
      /* storage unavailable: theme still applies for this visit */
    }
  }, [theme]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const mod = e.metaKey || e.ctrlKey;
      if (mod && e.key.toLowerCase() === 'k') {
        e.preventDefault();
        setPalette((x) => !x);
      } else if (mod && ['1', '2', '3'].includes(e.key)) {
        e.preventDefault();
        location.hash = { '1': 'overview', '2': 'inbox', '3': 'bots' }[e.key as '1' | '2' | '3'];
      } else if (e.key === 'Escape') {
        setPalette(false);
        setNewTask(false);
        setConn(false);
        setNav(false);
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);

  const openNav = useCallback(() => setNav(true), []);
  const openNewTask = useCallback(() => setNewTask(true), []);
  const currentBoard = route.view === 'board' ? route.slug : 'default';

  return (
    <NavContext.Provider value={{ openNav }}>
      <div className={`window${nav ? ' nav-open' : ''}`}>
        <Sidebar state={state} route={route} onPalette={() => setPalette(true)} onConnection={() => setConn((x) => !x)} />
        {nav && <div className="scrim" style={{ zIndex: 44 }} onClick={() => setNav(false)} />}
        <main className="main">
          {route.view === 'overview' && <Overview state={state} />}
          {route.view === 'inbox' && <InboxView state={state} />}
          {route.view === 'bots' && <BotsGrid state={state} />}
          {route.view === 'bot' && <BotDetail state={state} botId={route.id} />}
          {route.view === 'board' && <BoardView state={state} slug={route.slug} taskId={route.taskId} onNewTask={openNewTask} />}
          <Toasts toasts={state.toasts} />
        </main>
        {palette && <CommandPalette state={state} onClose={() => setPalette(false)} onNewTask={openNewTask} />}
        {newTask && <NewTaskSheet state={state} board={currentBoard} onClose={() => setNewTask(false)} />}
        {conn && <ConnectionPopover state={state} theme={theme} setTheme={setThemeState} onClose={() => setConn(false)} />}
      </div>
    </NavContext.Provider>
  );
}
