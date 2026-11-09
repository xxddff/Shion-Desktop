import { Download, FileText, Lock, MonitorOff, Smartphone } from 'lucide-react';
import type { Screen } from '../data/model';
import { hm, useNow } from '../ui/format';

/** Where your typing lands on the remote screen: the field you last clicked. */
export interface ScreenCaret {
  field: string;
  /** A click into the address bar selects all of it, as browsers do; the first key replaces it. */
  selectAll: boolean;
}

/** A field's text on the mock screen: what you typed, or what the page started with. */
export function fieldText(screen: Screen | undefined, field: string): string {
  const typed = screen?.typed?.[field];
  if (typed !== undefined) return typed;
  if (field === 'url') return screen?.url ?? '';
  if (field === 'from') return '吉祥寺';
  return '';
}

/**
 * A stand-in for the bot's cloud desktop (an Xfce screen streamed over RFB).
 * Drawn with HTML and sized in container units so the same mock works as a
 * thumbnail and as the full viewer. Example content only. Fields carry
 * `data-field` so the viewer knows which one a click landed in.
 */
export function ScreenMock({ screen, live = false, caret }: { screen: Screen; live?: boolean; caret?: ScreenCaret }) {
  const now = useNow(30_000);
  if (!screen.running) {
    return (
      <div className="scr off" role="img" aria-label="云桌面未启动">
        <MonitorOff className="scr-off-icon" />
        <span>未启动</span>
      </div>
    );
  }
  const human = screen.control === 'you';
  return (
    <div className={`scr${human ? ' human' : ''}`} role="img" aria-label={`云桌面：${screen.activity ?? ''}`}>
      <div className="scr-panel">
        <span>应用程序</span>
        <span className="grow" />
        <span>{hm(now)}</span>
      </div>
      <div className="scr-win">
        <div className="scr-chrome">
          <span className="scr-dots">
            <i />
            <i />
            <i />
          </span>
          <span className="scr-url" data-field="url">
            <Field screen={screen} id="url" caret={caret} />
          </span>
        </div>
        <div className="scr-page">
          {screen.app === 'sso' && <SsoPage />}
          {screen.app === 'moodle' && <CoursePage />}
          {screen.app === 'news' && <NewsPage />}
          {screen.app === 'transit' && <TransitPage screen={screen} caret={caret} />}
        </div>
      </div>
      {live && !human && <span className={`scr-cursor app-${screen.app}`} aria-hidden="true" />}
    </div>
  );
}

function Field({ screen, id, caret, placeholder }: { screen: Screen; id: string; caret?: ScreenCaret; placeholder?: string }) {
  const text = fieldText(screen, id);
  const on = caret?.field === id;
  if (on && caret.selectAll && text) return <span className="scr-sel">{text}</span>;
  return (
    <>
      {text ? <span className="scr-text">{text}</span> : !on && placeholder ? <span className="scr-ph">{placeholder}</span> : null}
      {on && <span className="scr-caret" />}
    </>
  );
}

function SsoPage() {
  return (
    <div className="pg-sso">
      <div className="sso-card">
        <div className="sso-title">
          <Lock /> 统一认证
        </div>
        <div className="sso-field">
          <span>学号</span>
          <b>24C1047</b>
        </div>
        <div className="sso-field">
          <span>密码</span>
          <b>••••••••••</b>
        </div>
        <div className="sso-2fa">
          <Smartphone />
          请在手机上的认证 App 里批准这次登录
        </div>
        <div className="sso-btn">登录</div>
      </div>
    </div>
  );
}

function CoursePage() {
  return (
    <div className="pg-course">
      <div className="pg-bar">课程平台</div>
      <div className="pg-crumb">我的课程 › 数据结构与算法 › 第7回 堆与优先队列</div>
      {[
        { t: '第7回 课件.pdf', m: '3.2 MB', dl: true },
        { t: '第7回 课堂录音（链接到 Notion）', m: '52 分钟' },
        { t: '作业4：用数组实现二叉堆', m: '截止 周五 23:59' },
        { t: '第8回 预习：教材 7.3 节', m: '' },
      ].map((r) => (
        <div key={r.t} className={`pg-row${r.dl ? ' hl' : ''}`}>
          <FileText />
          <span className="grow">{r.t}</span>
          <span className="pg-meta">{r.m}</span>
          {r.dl && <Download />}
        </div>
      ))}
    </div>
  );
}

function NewsPage() {
  return (
    <div className="pg-course">
      <div className="pg-bar dark">新闻</div>
      <div className="pg-h">电力公司公布 12 月电费：标准家庭比 11 月高约 4%</div>
      <div className="pg-p">政府的电费补贴在 11 月使用量后结束，12 月账单起恢复原价……</div>
      <div className="pg-p dim">相关：社交网络流传「上涨 30%」的说法，口径与官方不同</div>
      <div className="pg-p dim">主管部门：补贴退出后的影响将在下月公布</div>
    </div>
  );
}

function TransitPage({ screen, caret }: { screen: Screen; caret?: ScreenCaret }) {
  return (
    <div className="pg-course">
      <div className="pg-bar green">运行信息 · 东京近郊</div>
      <div className="pg-search">
        <span className="pg-input" data-field="from">
          <em>出发</em>
          <Field screen={screen} id="from" caret={caret} placeholder="车站名" />
        </span>
        <span className="pg-to">→</span>
        <span className="pg-input" data-field="to">
          <em>到达</em>
          <Field screen={screen} id="to" caret={caret} placeholder="车站名" />
        </span>
        <span className="pg-go">搜索路线</span>
      </div>
      {[
        ['中央線快速', '平常运行'],
        ['京王線', '平常运行'],
        ['井の頭線', '平常运行'],
        ['山手線', '平常运行'],
      ].map(([l, st]) => (
        <div key={l} className="pg-row">
          <span className="grow">{l}</span>
          <span className="pg-ok">{st}</span>
        </div>
      ))}
    </div>
  );
}
