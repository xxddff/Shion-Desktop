import { Hand, MousePointer2, Play, ShieldAlert } from 'lucide-react';
import { ScreenMock } from '../components/Screen';
import { Toolbar } from '../components/Shell';
import type { AppState, Screen } from '../data/model';
import { handBack, startScreen, takeOver } from '../data/store';
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
                <button className="btn primary" onClick={() => handBack(bot.id)}>
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
            {screen.control === 'you' && <div className="viewer-banner human">你的键盘和鼠标正在操作这块桌面，助手的操作会被拒绝，直到你交还。</div>}
            <ScreenMock screen={screen} live />
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
