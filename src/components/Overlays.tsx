import { Bot as BotIcon, CircleAlert, CircleCheck, Inbox, LayoutDashboard, Plus, SquareKanban, X } from 'lucide-react';
import { useEffect, useMemo, useRef, useState } from 'react';
import type { AppState, Toast } from '../data/model';
import { createTask, dismissToast, setSimulate } from '../data/store';
import { BOARD_COLUMNS, type KanbanTask, type TaskStatus } from '../protocol/kanban';
import { taskHref } from '../route';
import { Avatar, TASK_STATUS, TaskStatusIcon, toneVar } from '../ui/bits';

// ------------------------------------------------------------ command palette

interface PaletteItem {
  group: string;
  label: string;
  hint?: string;
  icon: JSX.Element;
  run: () => void;
}

export function CommandPalette({ state, onClose, onNewTask }: { state: AppState; onClose: () => void; onNewTask: () => void }) {
  const [q, setQ] = useState('');
  const [sel, setSel] = useState(0);
  const go = (hash: string) => () => {
    location.hash = hash;
    onClose();
  };
  const all = useMemo<PaletteItem[]>(
    () => [
      { group: '跳转', label: '总览', icon: <LayoutDashboard size={15} />, run: go('overview') },
      { group: '跳转', label: '待处理', hint: `${state.inbox.length} 条`, icon: <Inbox size={15} />, run: go('inbox') },
      { group: '跳转', label: '全部 Bots', icon: <BotIcon size={15} />, run: go('bots') },
      ...state.boards.map((b) => ({ group: '看板', label: b.name, hint: b.slug, icon: <SquareKanban size={15} />, run: go(`board-${b.slug}`) })),
      ...state.bots.map((b) => ({ group: 'Bots', label: b.displayName, hint: b.role, icon: <Avatar bot={b} size={18} />, run: go(`bot-${b.id}`) })),
      {
        group: '操作',
        label: '新建任务',
        icon: <Plus size={15} />,
        run: () => {
          onClose();
          onNewTask();
        },
      },
      {
        group: '操作',
        label: state.simulate ? '暂停实时模拟' : '恢复实时模拟',
        icon: <CircleAlert size={15} />,
        run: () => {
          setSimulate(!state.simulate);
          onClose();
        },
      },
      ...state.tasks.map((t) => ({
        group: '任务',
        label: t.title,
        hint: t.id,
        icon: <TaskStatusIcon status={t.status} />,
        run: go(taskHref(t.id).slice(1)),
      })),
    ],
    [state.bots, state.boards, state.tasks, state.inbox.length, state.simulate],
  );
  const items = useMemo(() => {
    const k = q.trim().toLowerCase();
    const list = k ? all.filter((i) => `${i.label} ${i.hint ?? ''}`.toLowerCase().includes(k)) : all.filter((i) => i.group !== '任务');
    return list.slice(0, 40);
  }, [q, all]);
  useEffect(() => setSel(0), [q]);

  return (
    <>
      <div className="scrim" onClick={onClose} />
      <div className="palette" role="dialog" aria-label="搜索">
        <input
          id="palette-input"
          autoFocus
          placeholder="搜索 Bot、看板、任务，或输入操作…"
          value={q}
          onChange={(e) => setQ(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'ArrowDown') {
              e.preventDefault();
              setSel((x) => Math.min(items.length - 1, x + 1));
            } else if (e.key === 'ArrowUp') {
              e.preventDefault();
              setSel((x) => Math.max(0, x - 1));
            } else if (e.key === 'Enter') {
              items[sel]?.run();
            } else if (e.key === 'Escape') {
              onClose();
            }
          }}
        />
        <ul role="listbox">
          {items.length === 0 && <li className="empty">没有匹配「{q}」的结果</li>}
          {items.map((it, i) => (
            <li key={`${it.group}-${it.label}-${it.hint}`}>
              {(i === 0 || items[i - 1].group !== it.group) && <div className="grp">{it.group}</div>}
              <button role="option" aria-selected={i === sel} onMouseEnter={() => setSel(i)} onClick={it.run}>
                {it.icon}
                <span style={{ flex: 1, minWidth: 0, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{it.label}</span>
                {it.hint && (
                  <span className="faint mono" style={{ maxWidth: 200, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                    {it.hint}
                  </span>
                )}
              </button>
            </li>
          ))}
        </ul>
      </div>
    </>
  );
}

// ------------------------------------------------------------ new task sheet

export function NewTaskSheet({ state, board, onClose }: { state: AppState; board: string; onClose: () => void }) {
  const [title, setTitle] = useState('');
  const [body, setBody] = useState('');
  const [assignee, setAssignee] = useState<string>('');
  const [priority, setPriority] = useState<KanbanTask['priority']>(1);
  const [status, setStatus] = useState<TaskStatus>('triage');
  const [slug, setSlug] = useState(board);
  const submit = (e: React.FormEvent) => {
    e.preventDefault();
    if (!title.trim()) return;
    const id = createTask({ title: title.trim(), body: body.trim(), assignee: assignee || null, priority, board: slug, status });
    onClose();
    location.hash = taskHref(id).slice(1);
  };
  return (
    <>
      <div className="scrim" onClick={onClose} />
      <form className="sheet" onSubmit={submit} onKeyDown={(e) => e.key === 'Escape' && onClose()}>
        <h2>新建任务</h2>
        <div className="form-row">
          <label htmlFor="nt-title">标题</label>
          <input id="nt-title" className="field" autoFocus value={title} onChange={(e) => setTitle(e.target.value)} placeholder="例如：给收件箱加系统通知" />
        </div>
        <div className="form-row">
          <label htmlFor="nt-body">说明</label>
          <textarea id="nt-body" className="field" rows={3} value={body} onChange={(e) => setBody(e.target.value)} placeholder="会作为 worker 的任务上下文" />
        </div>
        <div className="form-grid">
          <div className="form-row">
            <label htmlFor="nt-assignee">负责 Bot</label>
            <select id="nt-assignee" className="field" value={assignee} onChange={(e) => setAssignee(e.target.value)}>
              <option value="">先不分配</option>
              {state.bots.map((b) => (
                <option key={b.id} value={b.id}>
                  {b.displayName}
                </option>
              ))}
            </select>
          </div>
          <div className="form-row">
            <label htmlFor="nt-prio">优先级</label>
            <select id="nt-prio" className="field" value={priority} onChange={(e) => setPriority(Number(e.target.value) as KanbanTask['priority'])}>
              <option value={3}>紧急</option>
              <option value={2}>高</option>
              <option value={1}>中</option>
              <option value={0}>低</option>
            </select>
          </div>
          <div className="form-row">
            <label htmlFor="nt-status">放到</label>
            <select id="nt-status" className="field" value={status} onChange={(e) => setStatus(e.target.value as TaskStatus)}>
              {BOARD_COLUMNS.filter((c) => c !== 'running' && c !== 'done').map((c) => (
                <option key={c} value={c}>
                  {TASK_STATUS[c].label}
                </option>
              ))}
            </select>
          </div>
        </div>
        <div className="form-row">
          <label htmlFor="nt-board">看板</label>
          <select id="nt-board" className="field" value={slug} onChange={(e) => setSlug(e.target.value)}>
            {state.boards.map((b) => (
              <option key={b.slug} value={b.slug}>
                {b.name}
              </option>
            ))}
          </select>
        </div>
        <div className="actions" style={{ justifyContent: 'flex-end' }}>
          <span className="faint" style={{ marginRight: 'auto', fontSize: 11.5 }}>
            POST /api/plugins/kanban/tasks
          </span>
          <button type="button" className="btn" onClick={onClose}>
            取消
          </button>
          <button type="submit" className="btn primary" disabled={!title.trim()}>
            创建
          </button>
        </div>
      </form>
    </>
  );
}

// ------------------------------------------------------------ connection

type Theme = 'system' | 'light' | 'dark';

export function ConnectionPopover({
  state,
  theme,
  setTheme,
  onClose,
}: {
  state: AppState;
  theme: Theme;
  setTheme: (t: Theme) => void;
  onClose: () => void;
}) {
  const c = state.connection;
  return (
    <>
      <div className="scrim" style={{ background: 'transparent' }} onClick={onClose} />
      <div className="popover" role="dialog" aria-label="连接">
        <div className="section-title">Hermes 连接（示例）</div>
        <dl>
          <dt>Gateway</dt>
          <dd className="mono">{c.url}</dd>
          <dt>子协议</dt>
          <dd className="mono">{c.subprotocol}</dd>
          <dt>Profile</dt>
          <dd className="mono">
            {c.profileId} · {c.instanceId}
          </dd>
          <dt>能力</dt>
          <dd className="chips">
            {c.capabilities.map((x) => (
              <span key={x} className="chip mono">
                {x}
              </span>
            ))}
          </dd>
          <dt>Kanban</dt>
          <dd className="mono">{c.kanbanUrl}</dd>
          <dt>事件游标</dt>
          <dd className="mono num">since={c.lastEventId}</dd>
        </dl>
        <label className="switch" htmlFor="sim-toggle">
          <span>实时模拟（假数据）</span>
          <input id="sim-toggle" type="checkbox" checked={state.simulate} onChange={(e) => setSimulate(e.target.checked)} />
        </label>
        <div className="switch">
          <span>外观</span>
          <div className="segmented" role="group" aria-label="外观">
            {(['system', 'light', 'dark'] as Theme[]).map((t) => (
              <button key={t} aria-pressed={theme === t} onClick={() => setTheme(t)}>
                {{ system: '跟随系统', light: '浅色', dark: '深色' }[t]}
              </button>
            ))}
          </div>
        </div>
      </div>
    </>
  );
}

// ------------------------------------------------------------ toasts

export function Toasts({ toasts }: { toasts: Toast[] }) {
  useEffect(() => {
    if (toasts.length === 0) return;
    const oldest = toasts[0];
    const id = window.setTimeout(() => dismissToast(oldest.id), 6000);
    return () => window.clearTimeout(id);
  }, [toasts]);
  const ref = useRef<HTMLDivElement>(null);
  return (
    <div className="toasts" ref={ref} aria-live="polite">
      {toasts.map((t) => (
        <a key={t.id} className="toast" href={t.href} onClick={() => dismissToast(t.id)}>
          {t.tone === 'good' ? <CircleCheck size={16} color="var(--good)" /> : <CircleAlert size={16} color={`var(--${toneVar(t.tone)})`} />}
          <span>
            <div className="t">{t.title}</div>
            {t.body && <div className="b">{t.body}</div>}
          </span>
          <button
            className="btn ghost icon"
            style={{ width: 20, height: 20 }}
            aria-label="关闭"
            onClick={(e) => {
              e.preventDefault();
              e.stopPropagation();
              dismissToast(t.id);
            }}
          >
            <X size={12} />
          </button>
        </a>
      ))}
    </div>
  );
}
