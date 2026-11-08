import { Hand, MousePointer2, Play, ShieldAlert } from 'lucide-react';
import { useEffect, useRef, useState } from 'react';
import { ScreenMock } from '../components/Screen';
import { Toolbar } from '../components/Shell';
import type { AppState, Bot, Screen } from '../data/model';
import { getState, handBack, startScreen, takeOver } from '../data/store';
import { go } from '../route';
import { Avatar } from '../ui/bits';

export function ControlChip({ screen }: { screen: Screen }) {
  if (!screen.running) return <span className="pill tone-neutral">未启动</span>;
  if (screen.control === 'you')
    return (
      <span className="pill tone-critical">
        <Hand size={11} />
        你在操作
      </span>
    );
  if (screen.needsHuman)
    return (
      <span className="pill tone-warning">
        <ShieldAlert size={11} />
        等你接管
      </span>
    );
  return (
    <span className="pill tone-info">
      <MousePointer2 size={11} />
      助手在操作
    </span>
  );
}

/**
 * Each assistant's own desktop on the VPS (Hermes Bot Screen). Watch it, take
 * over for sign-ins, 2FA, CAPTCHAs or payments, then hand it back.
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

  return (
    <>
      <Toolbar title="云桌面" sub={`每个助手在 VPS 上有自己的桌面 · ${running} 个在运行`} />
      <div className="view">
        <div className="pad desk-layout">
          <section className="viewer">
            <div className="viewer-head">
              <Avatar bot={bot} size={26} />
              <div className="vh-main">
                <div className="vh-name">{bot.name} 的桌面</div>
                <div className="faint">{screen.running ? screen.activity : '没在用的时候不启动，需要时会自动打开'}</div>
              </div>
              <ControlChip screen={screen} />
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
            </div>
            {screen.needsHuman && screen.control === 'bot' && (
              <div className="viewer-banner">
                <ShieldAlert size={14} />
                <span className="grow">
                  「{bot.name}」停下来等你：{screen.needsHuman}。接管后完成这一步，再点「交还」。
                </span>
                <button className="btn primary mini" onClick={() => takeOver(bot.id)}>
                  接管
                </button>
              </div>
            )}
            {screen.control === 'you' && (
              <div className="viewer-banner human">你在操作这块桌面，助手暂停。点画面外面或「交还」把控制权还给它；切到别的 App（比如去看验证码）不会交还。</div>
            )}
            <LiveScreen key={bot.id} bot={bot} screen={screen} />
            <p className="faint viewer-note">
              画面在 VPS 上，你关掉 Mac 它也照常运行。助手的浏览器登录状态会保留，你接管登录过一次的网站，之后它可以自己用。
            </p>
          </section>

          <aside className="screen-list" aria-label="所有助手的桌面">
            {screens.map(({ bot: b, screen: s }) => (
              <button key={b.id} className={`screen-card${b.id === bot.id ? ' on' : ''}`} onClick={() => go(`desktop-${b.id}`)}>
                <ScreenMock screen={s} />
                <span className="sc-meta">
                  <Avatar bot={b} size={18} />
                  <span className="grow">{b.name}</span>
                  <ControlChip screen={s} />
                </span>
              </button>
            ))}
          </aside>
        </div>
      </div>
    </>
  );
}

const RELEASE_MS = 3000;
/** How many live viewers are mounted per bot. */
const openViewers = new Map<string, number>();

/**
 * The full-size screen. Click it to take over (`display.lease.acquire`); click
 * anywhere else in Shion to hand back (`display.lease.release`) after a short
 * grace period, so a stray click mid-login can be undone by clicking back in.
 * Leaving the page hands back at once, like closing the pane in Hermes Desktop.
 * Switching to another app does not hand back.
 */
function LiveScreen({ bot, screen }: { bot: Bot; screen: Screen }) {
  const hitRef = useRef<HTMLDivElement>(null);
  const [armed, setArmed] = useState(false);
  const [releasing, setReleasing] = useState(false);
  const held = screen.control === 'you';
  // a bot in the middle of its own work needs a second click, so a glance never interrupts it
  const busy = bot.status === 'working' && !screen.needsHuman;

  useEffect(() => {
    if (!armed) return;
    const t = window.setTimeout(() => setArmed(false), 3000);
    return () => window.clearTimeout(t);
  }, [armed]);

  useEffect(() => {
    if (!held) {
      setReleasing(false);
      return;
    }
    const down = (e: MouseEvent) => {
      const target = e.target as HTMLElement;
      if (hitRef.current?.contains(target) || target.closest('[data-keeps-control]')) return;
      setReleasing(true);
    };
    document.addEventListener('mousedown', down);
    return () => document.removeEventListener('mousedown', down);
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

  const onClick = () => {
    if (!screen.running) return;
    if (held) {
      setReleasing(false);
      return;
    }
    if (busy && !armed) {
      setArmed(true);
      return;
    }
    setArmed(false);
    takeOver(bot.id);
  };

  return (
    <div
      ref={hitRef}
      className={`screen-hit${held ? ' held' : ''}${screen.running ? '' : ' off'}`}
      onMouseDown={onClick}
      role={held ? undefined : 'button'}
      tabIndex={held || !screen.running ? -1 : 0}
      aria-label={held ? `${bot.name} 的桌面（你在操作）` : `点击接管 ${bot.name} 的桌面`}
      onKeyDown={(e) => {
        if (!held && (e.key === 'Enter' || e.key === ' ')) {
          e.preventDefault();
          onClick();
        }
      }}
    >
      <ScreenMock screen={screen} live />
      {screen.running && !held && (
        <div className={`hit-hint${armed || screen.needsHuman ? ' show' : ''}`}>
          <Hand size={16} />
          {armed ? `「${bot.name}」正在用这块桌面，再点一次接管` : screen.needsHuman ? '点击画面接管，完成这一步' : '点击画面接管'}
        </div>
      )}
      {held && !releasing && <div className="held-tag">你在操作 · 点画面外交还</div>}
      {releasing && (
        <div className="release-bar">
          <span>马上交还给{bot.name}… 点画面继续操作</span>
          <i style={{ animationDuration: `${RELEASE_MS}ms` }} />
        </div>
      )}
    </div>
  );
}
