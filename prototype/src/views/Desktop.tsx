import { Hand, Play } from 'lucide-react';
import { useEffect, useRef, useState } from 'react';
import { ScreenMock, fieldText, type ScreenCaret } from '../components/Screen';
import { Toolbar } from '../components/Shell';
import type { AppState, Bot, Screen } from '../data/model';
import { getState, handBack, startScreen, takeOver, typeOnScreen } from '../data/store';
import { go } from '../route';
import { Avatar } from '../ui/bits';

/** Who holds the screen, in words, with the tone it deserves. */
export function screenState(screen: Screen): { text: string; tone: 'red' | 'warm' | 'quiet' } {
  if (!screen.running) return { text: '未启动', tone: 'quiet' };
  if (screen.control === 'you') return { text: '你在操作', tone: 'red' };
  if (screen.needsHuman) return { text: `等你接管：${screen.needsHuman}`, tone: 'warm' };
  return { text: screen.activity ?? '空闲', tone: 'quiet' };
}

/**
 * Each assistant's own desktop on the VPS (Hermes Bot Screen). Watch it, take
 * over for sign-ins, two-step codes, CAPTCHAs or payments, then hand it back.
 */
export function DesktopView({ state, botId }: { state: AppState; botId?: string }) {
  const screens = state.bots.map((b) => ({ bot: b, screen: state.screens[b.id] ?? { botId: b.id, running: false, control: 'bot' as const } }));
  const pick =
    screens.find((x) => x.bot.id === botId) ??
    screens.find((x) => x.screen.needsHuman || x.screen.control === 'you') ??
    screens.find((x) => x.screen.running) ??
    screens[0];
  const { bot, screen } = pick;
  const running = screens.filter((x) => x.screen.running).length;
  const st = screenState(screen);

  return (
    <>
      <Toolbar title="云桌面" sub={`${running} 块在运行`} />
      <div className="view">
        <div className="page deskview">
          <section className="viewer">
            <header className="viewer-head">
              <Avatar bot={bot} size={28} />
              <div className="viewer-titles">
                <h2>{bot.name}的桌面</h2>
                <p className={st.tone}>{st.text}</p>
              </div>
              {!screen.running ? (
                <button className="btn" onClick={() => startScreen(bot.id)}>
                  <Play size={13} />
                  启动
                </button>
              ) : screen.control === 'you' ? (
                <button className="btn primary" data-keeps-control onClick={() => handBack(bot.id)}>
                  交还给{bot.name}
                </button>
              ) : (
                <button className={`btn${screen.needsHuman ? ' primary' : ''}`} onClick={() => takeOver(bot.id)}>
                  <Hand size={13} />
                  接管
                </button>
              )}
            </header>
            <LiveScreen key={bot.id} bot={bot} screen={screen} />
            <p className="viewer-note">画面在 VPS 上运行，合上 Mac 也不影响。你帮它登录过的网站，之后它能自己用。</p>
          </section>

          <aside className="screens" aria-label="所有桌面">
            <h3 className="screens-title">所有桌面</h3>
            {screens.map(({ bot: b, screen: s }) => {
              const t = screenState(s);
              return (
                <button key={b.id} className={`screen-item${b.id === bot.id ? ' on' : ''}${s.running ? '' : ' off'}`} onClick={() => go(`desktop-${b.id}`)}>
                  {s.running ? (
                    <span className="screen-thumb">
                      <ScreenMock screen={s} />
                    </span>
                  ) : (
                    <Avatar bot={b} size={22} />
                  )}
                  <span className="screen-text">
                    <b>{b.name}</b>
                    <span className={t.tone}>{t.text}</span>
                  </span>
                </button>
              );
            })}
          </aside>
        </div>
      </div>
    </>
  );
}

const RELEASE_MS = 3000;
/** How many live viewers are mounted per bot. */
const openViewers = new Map<string, number>();

/** Where you last clicked on the screen you hold, in viewer pixels, and the field under it. */
type Spot = { x: number; y: number; caret: ScreenCaret | null };

/**
 * The full-size screen. Click it to take over (`display.lease.acquire`); click
 * anywhere else in Shion to hand back (`display.lease.release`) after a short
 * grace period, so a stray click mid-login can be undone by clicking back in.
 * Leaving the page hands back at once, like closing the pane in Hermes Desktop.
 * Switching to another app does not hand back.
 *
 * While you hold it, typing goes to the remote field you last clicked, and the
 * Mac's input method composes right at that spot: the native app sends plain
 * keys as key events and a committed Chinese or Japanese string as a paste, so
 * the remote desktop needs no input method of its own.
 */
function LiveScreen({ bot, screen }: { bot: Bot; screen: Screen }) {
  const hitRef = useRef<HTMLDivElement>(null);
  const imeRef = useRef<HTMLInputElement>(null);
  const [armed, setArmed] = useState(false);
  const [releasing, setReleasing] = useState(false);
  const [spot, setSpotState] = useState<Spot | null>(null);
  const spotRef = useRef<Spot | null>(null);
  const [marked, setMarked] = useState('');
  const composingRef = useRef(false);
  const held = screen.control === 'you';
  // a bot in the middle of its own work needs a second click, so a glance never interrupts it
  const busy = bot.status === 'working' && !screen.needsHuman;

  const setSpot = (next: Spot | null) => {
    spotRef.current = next;
    setSpotState(next);
  };

  useEffect(() => {
    if (!armed) return;
    const t = window.setTimeout(() => setArmed(false), 3000);
    return () => window.clearTimeout(t);
  }, [armed]);

  // each click on the screen you hold moves the typing spot there
  useEffect(() => {
    if (spot) imeRef.current?.focus({ preventScroll: true });
  }, [spot]);

  useEffect(() => {
    if (!held) {
      setReleasing(false);
      setSpot(null);
      setMarked('');
      composingRef.current = false;
      return;
    }
    const down = (e: MouseEvent) => {
      const target = e.target as HTMLElement;
      if (hitRef.current?.contains(target) || target.closest('[data-keeps-control]')) return;
      setReleasing(true);
    };
    // capture phase: decide before React re-renders the screen, which can detach the clicked node
    // (a field's placeholder disappears as soon as the caret lands in it)
    document.addEventListener('mousedown', down, true);
    return () => document.removeEventListener('mousedown', down, true);
  }, [held]);

  useEffect(() => {
    if (!releasing) return;
    const t = window.setTimeout(() => handBack(bot.id), RELEASE_MS);
    return () => window.clearTimeout(t);
  }, [releasing, bot.id]);

  // leaving this screen (another page, another bot) hands it back immediately; the deferred
  // check skips React's development double-mount, which remounts before the timeout runs
  useEffect(() => {
    const id = bot.id;
    openViewers.set(id, (openViewers.get(id) ?? 0) + 1);
    return () => {
      openViewers.set(id, (openViewers.get(id) ?? 1) - 1);
      window.setTimeout(() => {
        if (!openViewers.get(id) && getState().screens[id]?.control === 'you') handBack(id);
      }, 0);
    };
  }, [bot.id]);

  const tryTakeOver = () => {
    if (!screen.running || held) return;
    if (busy && !armed) {
      setArmed(true);
      return;
    }
    setArmed(false);
    // the click that takes over is not passed on, so it can never press 「登录」 or 「付款」 by accident
    takeOver(bot.id);
  };

  const onPress = (e: React.MouseEvent<HTMLDivElement>) => {
    if (!held) return tryTakeOver();
    setReleasing(false);
    // a click on the screen you hold is a click on the remote desktop: the remote focus moves
    // there, and so does the spot where the Mac's input method composes
    e.preventDefault();
    const box = e.currentTarget.getBoundingClientRect();
    const field = (e.target as HTMLElement).closest<HTMLElement>('[data-field]')?.dataset.field;
    setSpot({ x: e.clientX - box.left, y: e.clientY - box.top, caret: field ? { field, selectAll: field === 'url' } : null });
  };

  /** Apply an edit to the field you last clicked, the way the remote page would. */
  const write = (edit: (text: string) => string) => {
    const at = spotRef.current;
    if (!at?.caret) return;
    const { field, selectAll } = at.caret;
    typeOnScreen(bot.id, field, edit(selectAll ? '' : fieldText(getState().screens[bot.id], field)));
    if (selectAll) setSpot({ ...at, caret: { field, selectAll: false } });
  };
  const commit = (text: string) => {
    if (text) write((t) => t + text);
  };

  return (
    <div
      ref={hitRef}
      className={`screen-hit${held ? ' held' : ''}${screen.running ? '' : ' off'}`}
      onMouseDown={onPress}
      role={held ? undefined : 'button'}
      tabIndex={held || !screen.running ? -1 : 0}
      aria-label={held ? `${bot.name}的桌面（你在操作）` : `点击接管${bot.name}的桌面`}
      onKeyDown={(e) => {
        if (!held && (e.key === 'Enter' || e.key === ' ')) {
          e.preventDefault();
          tryTakeOver();
        }
      }}
    >
      <ScreenMock screen={screen} live caret={held ? spot?.caret ?? undefined : undefined} />
      {held && spot && (
        <>
          {/* catches keys and the input method's composition; invisible, so the candidate window
              opens at the spot you clicked */}
          <input
            ref={imeRef}
            className="ime-catch"
            style={{ left: spot.x, top: spot.y }}
            aria-label={`在${bot.name}的桌面上打字`}
            autoComplete="off"
            autoCorrect="off"
            autoCapitalize="off"
            spellCheck={false}
            onCompositionStart={() => {
              composingRef.current = true;
              setMarked('');
            }}
            onCompositionUpdate={(e) => setMarked(e.data)}
            onCompositionEnd={(e) => {
              composingRef.current = false;
              setMarked('');
              e.currentTarget.value = '';
              commit(e.data); // the app pastes this: ClientCutText, then Ctrl+V
            }}
            onInput={(e) => {
              const el = e.currentTarget;
              if (composingRef.current || (e.nativeEvent as InputEvent).isComposing || !el.value) return;
              commit(el.value); // the app sends these as key events
              el.value = '';
            }}
            onKeyDown={(e) => {
              // ⌘ and Ctrl shortcuts belong to the remote desktop while you hold it, not to Shion
              if (e.metaKey || e.ctrlKey) e.stopPropagation();
              if (composingRef.current || e.nativeEvent.isComposing || e.key === 'Process') return;
              if (e.key === 'Backspace') {
                e.preventDefault();
                write((t) => Array.from(t).slice(0, -1).join(''));
              } else if (e.key === 'Enter' || e.key === 'Tab' || e.key === 'Escape' || e.key.startsWith('Arrow')) {
                e.preventDefault();
              }
            }}
            onPaste={(e) => {
              e.preventDefault();
              commit(e.clipboardData.getData('text/plain'));
            }}
          />
          {marked && (
            <span className="ime-marked" style={{ left: spot.x, top: spot.y }} aria-hidden="true">
              {marked}
            </span>
          )}
        </>
      )}
      {screen.running && !held && (
        <div className={`hit-hint${armed || screen.needsHuman ? ' show' : ''}`}>
          <Hand size={15} />
          {armed ? `${bot.name}正在用，再点一次接管` : '点击画面接管'}
        </div>
      )}
      {held && !releasing && <div className="held-tag">你在操作 · 点画面外交还</div>}
      {releasing && (
        <div className="release-bar">
          <span>马上交还给{bot.name}，点画面继续操作</span>
          <i style={{ animationDuration: `${RELEASE_MS}ms` }} />
        </div>
      )}
    </div>
  );
}
