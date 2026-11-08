import { BellRing, Check, Clock, Flag } from 'lucide-react';
import type { AppState, Ask, Todo } from '../data/model';
import { answerAsk, confirmTodo, toggleTodo } from '../data/store';
import { AreaDot, Avatar } from '../ui/bits';
import { ago, until, when } from '../ui/format';

export function Checkbox({ done, onToggle, label }: { done: boolean; onToggle: () => void; label: string }) {
  return (
    <button className={`check${done ? ' on' : ''}`} onClick={onToggle} aria-pressed={done} aria-label={done ? `把「${label}」标为未完成` : `完成「${label}」`}>
      {done && <Check size={11} strokeWidth={3} />}
    </button>
  );
}

/** One todo, with its plan date (执行) and deadline (截止) side by side. */
export function TodoRow({ t, now, selected, onSelect }: { t: Todo; now: number; selected?: boolean; onSelect?: () => void }) {
  const dueSoon = t.dueAt != null && !t.done && t.dueAt - now < 24 * 3_600_000;
  const overdue = t.dueAt != null && !t.done && t.dueAt < now;
  return (
    <div className={`todo${t.done ? ' done' : ''}${selected ? ' selected' : ''}${t.proposed ? ' proposed' : ''}`}>
      <Checkbox done={t.done} onToggle={() => toggleTodo(t.id)} label={t.title} />
      <button className="todo-main" onClick={onSelect} disabled={!onSelect}>
        <span className="todo-title">{t.title}</span>
        <span className="todo-meta">
          <AreaDot area={t.area} />
          {t.source.label}
          {t.nudges > 0 && !t.done && (
            <span className="nudge" title={`紫苑已经提醒过 ${t.nudges} 次`}>
              <BellRing size={11} />
              催了 {t.nudges} 次
            </span>
          )}
        </span>
      </button>
      <span className="todo-dates">
        {t.doAt && (
          <span className="date-do" title="执行日期">
            <Clock size={11} />
            {when(t.doAt, now)}
          </span>
        )}
        {t.dueAt && (
          <span className={`date-due${overdue ? ' over' : dueSoon ? ' soon' : ''}`} title={`截止日期 · ${until(t.dueAt, now)}`}>
            <Flag size={11} />
            {when(t.dueAt, now)}
          </span>
        )}
      </span>
      {t.proposed && !t.done && (
        <button className="btn mini" onClick={() => confirmTodo(t.id)}>
          确认
        </button>
      )}
    </div>
  );
}

export function AskCard({ ask, state, now, compact = false }: { ask: Ask; state: AppState; now: number; compact?: boolean }) {
  const bot = state.bots.find((b) => b.id === ask.botId);
  return (
    <article className={`ask${compact ? ' compact' : ''} ${ask.kind}`}>
      <div className="ask-head">
        <Avatar bot={bot} size={compact ? 20 : 24} />
        <span className="who">{bot?.name}</span>
        <span className="faint">{ago(ask.at, now)}</span>
      </div>
      <div className="ask-title">{ask.title}</div>
      {!compact && ask.detail && <div className="muted">{ask.detail}</div>}
      {ask.preview && (
        <div className="preview">
          <div className="preview-label">{ask.preview.label}</div>
          {!compact && <div className="preview-body">{ask.preview.body}</div>}
        </div>
      )}
      <div className="actions">
        {ask.options.map((o) => (
          <button key={o.value} className={`btn${o.primary ? ' primary' : ''}${o.danger ? ' danger' : ''}${compact ? ' mini' : ''}`} onClick={() => answerAsk(ask, o.value)}>
            {o.label}
          </button>
        ))}
        {compact && ask.preview && (
          <a className="btn ghost mini" href="#confirm">
            看全文
          </a>
        )}
      </div>
    </article>
  );
}
