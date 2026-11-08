import { GitBranch, HeartPulse, Link2, MessageSquare, OctagonAlert, Plus, Search, Send, X } from 'lucide-react';
import { useState } from 'react';
import { Toolbar } from '../components/Shell';
import type { AppState, Bot } from '../data/model';
import { addComment, assignTask, moveTask } from '../data/store';
import { BOARD_COLUMNS, TASK_STATUSES, type KanbanTask, type TaskEvent, type TaskStatus } from '../protocol/kanban';
import { taskHref } from '../route';
import { Avatar, Priority, priorityLabel, TASK_STATUS, TaskStatusIcon, TaskStatusPill } from '../ui/bits';
import { ago, span, useNow } from '../ui/format';

export function BoardView({ state, slug, taskId, onNewTask }: { state: AppState; slug: string; taskId?: string; onNewTask: () => void }) {
  const now = useNow();
  const board = state.boards.find((b) => b.slug === slug);
  const [q, setQ] = useState('');
  const [who, setWho] = useState<string>('all');
  const [dragId, setDragId] = useState<string | null>(null);
  const [over, setOver] = useState<TaskStatus | null>(null);

  const all = state.tasks.filter((t) => t.board === slug && t.status !== 'archived');
  const tasks = all.filter(
    (t) =>
      (who === 'all' || (who === 'none' ? !t.assignee : t.assignee === who)) &&
      (!q || `${t.title} ${t.id} ${t.body}`.toLowerCase().includes(q.toLowerCase())),
  );
  const selected = taskId ? state.tasks.find((t) => t.id === taskId) : undefined;
  const botOf = (id: string | null) => state.bots.find((b) => b.id === id);
  const close = () => (location.hash = `board-${slug}`);

  return (
    <>
      <Toolbar
        title={board?.name ?? slug}
        sub={`board: ${slug} · ${all.length} 张卡片 · ${all.filter((t) => t.status === 'running').length} 运行中`}
      >
        <div className="segmented hide-narrow" role="group" aria-label="按负责人筛选">
          <button aria-pressed={who === 'all'} onClick={() => setWho('all')}>
            全部
          </button>
          {state.bots.map((b) => (
            <button key={b.id} aria-pressed={who === b.id} onClick={() => setWho(b.id)} title={b.displayName}>
              <Avatar bot={b} size={14} />
              {b.displayName}
            </button>
          ))}
        </div>
        <label className="search-field hide-narrow" htmlFor="board-search">
          <Search size={13} />
          <input id="board-search" placeholder="筛选卡片" value={q} onChange={(e) => setQ(e.target.value)} />
        </label>
        <button className="btn primary" onClick={onNewTask}>
          <Plus size={14} />
          <span className="hide-narrow">新建任务</span>
        </button>
      </Toolbar>
      <div className="view" style={{ overflow: 'hidden' }}>
        <div className="board-wrap">
          <div className="board">
            {BOARD_COLUMNS.map((col) => {
              const list = tasks.filter((t) => t.status === col).sort((a, b) => b.priority - a.priority || b.updatedAt - a.updatedAt);
              return (
                <section
                  key={col}
                  className={`column${over === col ? ' drop' : ''}`}
                  aria-label={TASK_STATUS[col].label}
                  onDragOver={(e) => {
                    e.preventDefault();
                    setOver(col);
                  }}
                  onDragLeave={() => setOver((o) => (o === col ? null : o))}
                  onDrop={(e) => {
                    e.preventDefault();
                    const id = e.dataTransfer.getData('text/plain');
                    if (id) moveTask(id, col);
                    setOver(null);
                    setDragId(null);
                  }}
                >
                  <div className="column-head">
                    <TaskStatusIcon status={col} />
                    {TASK_STATUS[col].label}
                    <span className="key">{col}</span>
                    <span className="n">{list.length}</span>
                  </div>
                  <div className="column-body">
                    {list.map((t) => (
                      <Card
                        key={t.id}
                        t={t}
                        bot={botOf(t.assignee)}
                        now={now}
                        selected={t.id === taskId}
                        dragging={t.id === dragId}
                        onDragStart={() => setDragId(t.id)}
                        onDragEnd={() => {
                          setDragId(null);
                          setOver(null);
                        }}
                      />
                    ))}
                  </div>
                </section>
              );
            })}
          </div>
          {selected && <Inspector t={selected} state={state} now={now} onClose={close} />}
        </div>
      </div>
    </>
  );
}

function Card(props: {
  t: KanbanTask;
  bot?: Bot;
  now: number;
  selected: boolean;
  dragging: boolean;
  onDragStart: () => void;
  onDragEnd: () => void;
}) {
  const { t, bot, now } = props;
  const stale = t.status === 'running' && t.lastHeartbeatAt != null && now - t.lastHeartbeatAt > 5 * 60_000;
  return (
    <a
      className={`card${props.dragging ? ' dragging' : ''}`}
      href={taskHref(t.id)}
      aria-selected={props.selected}
      draggable
      onDragStart={(e) => {
        e.dataTransfer.setData('text/plain', t.id);
        e.dataTransfer.effectAllowed = 'move';
        props.onDragStart();
      }}
      onDragEnd={props.onDragEnd}
      style={{ textDecoration: 'none', color: 'inherit' }}
    >
      <div className="row1">
        <span className="mono">{t.id}</span>
        <Priority p={t.priority} />
        {t.tenant && <span className="chip" style={{ height: 16, fontSize: 10.5 }}>{t.tenant}</span>}
      </div>
      <div className="title">{t.title}</div>
      {t.status === 'blocked' && t.block && (
        <div className={`blockline ${t.block.kind === 'needs_input' ? 'tone-warning' : 'tone-critical'}`}>
          <OctagonAlert size={12} style={{ flexShrink: 0, marginTop: 2 }} />
          <span>
            <b>{t.block.kind === 'needs_input' ? '需要你' : t.block.kind === 'capability' ? '缺少能力' : '暂时失败'}</b> · {t.block.reason}
          </span>
        </div>
      )}
      {t.status === 'running' && t.lastHeartbeatAt && (
        <div className="hb" style={stale ? { color: 'var(--warn)' } : undefined}>
          <HeartPulse size={12} color={stale ? 'var(--warn)' : 'var(--info)'} />
          <span>
            {ago(t.lastHeartbeatAt, now)} · {t.heartbeatNote}
          </span>
        </div>
      )}
      <div className="foot">
        {t.workspace.startsWith('worktree') && (
          <span title={t.workspace}>
            <GitBranch size={11} />
            worktree
          </span>
        )}
        {t.parents.length > 0 && (
          <span title={`依赖 ${t.parents.join(', ')}`}>
            <Link2 size={11} />
            {t.parents.length}
          </span>
        )}
        {t.comments.length > 0 && (
          <span>
            <MessageSquare size={11} />
            {t.comments.length}
          </span>
        )}
        <span className="who" title={bot ? `负责：${bot.displayName}` : '未分配'}>
          {bot ? <Avatar bot={bot} size={18} /> : <span className="faint">未分配</span>}
        </span>
      </div>
    </a>
  );
}

function eventSummary(e: TaskEvent): string {
  const p = e.payload;
  switch (e.kind) {
    case 'created':
      return `assignee=${p.assignee ?? '—'} status=${p.status}`;
    case 'claimed':
      return `lock=${p.lock} ttl=${p.expires}`;
    case 'heartbeat':
      return p.note ? String(p.note) : '';
    case 'blocked':
      return `${p.kind ?? ''} · ${p.reason ?? ''}`;
    case 'completed':
      return String(p.summary ?? '');
    case 'status':
      return `→ ${p.status}`;
    case 'assigned':
      return `→ ${p.assignee ?? '—'}`;
    case 'spawned':
      return `pid ${p.pid}`;
    case 'dependency_wait':
      return String(p.reason ?? '');
    case 'commented':
      return `by ${p.author}`;
    default:
      return Object.keys(p).length ? JSON.stringify(p) : '';
  }
}

const EVENT_TONE: Partial<Record<TaskEvent['kind'], string>> = {
  completed: 'good',
  claimed: 'info',
  heartbeat: 'info',
  blocked: 'critical',
  crashed: 'critical',
  timed_out: 'critical',
  unblocked: 'good',
};

function Inspector({ t, state, now, onClose }: { t: KanbanTask; state: AppState; now: number; onClose: () => void }) {
  const [tab, setTab] = useState<'comments' | 'events' | 'runs'>('comments');
  const [text, setText] = useState('');
  const botOf = (id: string) => state.bots.find((b) => b.id === id);
  return (
    <aside className="inspector" aria-label="任务详情" onKeyDown={(e) => e.key === 'Escape' && onClose()}>
      <div className="insp-head">
        <span className="mono faint">{t.id}</span>
        <TaskStatusPill status={t.status} />
        <button className="btn ghost icon" style={{ marginLeft: 'auto' }} onClick={onClose} aria-label="关闭详情">
          <X size={15} />
        </button>
      </div>
      <div className="insp-body">
        <h2>{t.title}</h2>
        {t.status === 'blocked' && t.block && (
          <div className={`blockline pill ${t.block.kind === 'needs_input' ? 'tone-warning' : 'tone-critical'}`} style={{ height: 'auto', padding: '8px 10px', borderRadius: 8, whiteSpace: 'normal', fontWeight: 500 }}>
            <OctagonAlert size={13} style={{ flexShrink: 0 }} />
            {t.block.reason}
          </div>
        )}
        <dl className="props">
          <dt>状态</dt>
          <dd>
            <select id="insp-status" className="field" value={t.status} onChange={(e) => moveTask(t.id, e.target.value as TaskStatus)}>
              {TASK_STATUSES.map((s) => (
                <option key={s} value={s}>
                  {TASK_STATUS[s].label} · {s}
                </option>
              ))}
            </select>
          </dd>
          <dt>负责</dt>
          <dd>
            <select id="insp-assignee" className="field" value={t.assignee ?? ''} onChange={(e) => assignTask(t.id, e.target.value || null)}>
              <option value="">未分配</option>
              {state.bots.map((b) => (
                <option key={b.id} value={b.id}>
                  {b.displayName}
                </option>
              ))}
            </select>
          </dd>
          <dt>优先级</dt>
          <dd>{priorityLabel(t.priority)}</dd>
          <dt>工作区</dt>
          <dd className="mono">{t.workspace}</dd>
          {t.skills.length > 0 && (
            <>
              <dt>技能</dt>
              <dd>
                {t.skills.map((s) => (
                  <span key={s} className="chip">
                    {s}
                  </span>
                ))}
              </dd>
            </>
          )}
          {t.parents.length > 0 && (
            <>
              <dt>依赖</dt>
              <dd>
                {t.parents.map((p) => (
                  <a key={p} className="chip mono" href={taskHref(p)}>
                    {p}
                  </a>
                ))}
              </dd>
            </>
          )}
          <dt>创建</dt>
          <dd className="muted">
            {t.createdBy === 'you' ? '你' : t.createdBy} · {ago(t.createdAt, now)}
          </dd>
          {t.status === 'running' && t.lastHeartbeatAt && (
            <>
              <dt>心跳</dt>
              <dd className="muted">
                <HeartPulse size={12} color="var(--info)" /> {ago(t.lastHeartbeatAt, now)}
              </dd>
            </>
          )}
        </dl>
        {t.body && <div className="body-text">{t.body}</div>}

        <div className="tabs" role="tablist">
          <button role="tab" aria-selected={tab === 'comments'} onClick={() => setTab('comments')}>
            评论 {t.comments.length}
          </button>
          <button role="tab" aria-selected={tab === 'events'} onClick={() => setTab('events')}>
            事件 {t.events.length}
          </button>
          <button role="tab" aria-selected={tab === 'runs'} onClick={() => setTab('runs')}>
            运行 {t.runs.length}
          </button>
        </div>

        {tab === 'comments' && (
          <div style={{ display: 'grid', gap: 12 }}>
            {t.comments.length === 0 && <span className="faint">还没有评论。评论是 Bot 之间交接的主要方式，worker 重新启动时会读完整条评论串。</span>}
            {t.comments.map((c) => (
              <div key={c.id} className="comment">
                <Avatar bot={c.author === 'you' ? undefined : botOf(c.author)} size={22} />
                <div style={{ minWidth: 0 }}>
                  <div className="meta">
                    <b>{c.author === 'you' ? '你' : botOf(c.author)?.displayName ?? c.author}</b>
                    {ago(c.at, now)}
                  </div>
                  <p>{c.body}</p>
                </div>
              </div>
            ))}
            <form
              className="actions"
              onSubmit={(e) => {
                e.preventDefault();
                if (!text.trim()) return;
                addComment(t.id, text.trim());
                setText('');
              }}
            >
              <input id={`comment-${t.id}`} className="field" style={{ flex: 1 }} placeholder="写评论，@ 某个 Bot 交代上下文…" value={text} onChange={(e) => setText(e.target.value)} />
              <button className="btn primary icon" type="submit" disabled={!text.trim()} aria-label="发送评论">
                <Send size={13} />
              </button>
            </form>
          </div>
        )}

        {tab === 'events' && (
          <ul className="timeline">
            {[...t.events].reverse().map((e) => (
              <li key={e.id}>
                <span className={`dot ${EVENT_TONE[e.kind] ?? ''}`} />
                <span style={{ minWidth: 0 }}>
                  <span className="k">{e.kind}</span> <span className="pl">{eventSummary(e)}</span>
                </span>
                <span className="faint num" style={{ fontSize: 11 }}>
                  {ago(e.at, now)}
                </span>
              </li>
            ))}
          </ul>
        )}

        {tab === 'runs' && (
          <div style={{ display: 'grid', gap: 8 }}>
            {t.runs.length === 0 && <span className="faint">还没有运行记录</span>}
            {[...t.runs].reverse().map((r) => (
              <div key={r.id} className="run">
                <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                  <span className={`pill tone-${r.outcome === 'completed' ? 'good' : r.outcome === 'running' ? 'info' : r.outcome === 'blocked' || r.outcome === 'crashed' ? 'critical' : 'warning'}`}>
                    {r.outcome}
                  </span>
                  <span className="mono faint">{r.id}</span>
                  <span className="faint" style={{ marginLeft: 'auto' }}>
                    {botOf(r.profile)?.displayName ?? r.profile} · {span((r.endedAt ?? now) - r.startedAt)}
                  </span>
                </div>
                {(r.summary || r.error) && <div className={r.error ? '' : 'muted'} style={r.error ? { color: 'var(--crit)' } : undefined}>{r.summary ?? r.error}</div>}
              </div>
            ))}
          </div>
        )}
      </div>
    </aside>
  );
}
