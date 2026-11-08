import { Check } from 'lucide-react';
import type { AppState, Ask, Todo } from '../data/model';
import { answerAsk, confirmTodo, toggleTodo } from '../data/store';
import { go } from '../route';
import { AreaDot, Avatar } from '../ui/bits';
import { ago, dueLabel, planLabel } from '../ui/format';

export function Checkbox({ done, onToggle, label }: { done: boolean; onToggle: () => void; label: string }) {
  return (
    <button className={`check${done ? ' on' : ''}`} onClick={onToggle} aria-pressed={done} aria-label={done ? `把「${label}」标为未完成` : `完成「${label}」`}>
      {done && <Check size={11} strokeWidth={3.2} />}
    </button>
  );
}

/**
 * One todo. The plan time (执行) reads quietly on the right; the deadline (截止)
 * only raises its voice when it is close or already past.
 */
export function TodoRow({
  t,
  now,
  withDay = true,
  selected,
  onSelect,
}: {
  t: Todo;
  now: number;
  withDay?: boolean;
  selected?: boolean;
  onSelect?: () => void;
}) {
  const plan = t.doAt != null ? planLabel(t.doAt, now, withDay) : '';
  const due = t.dueAt != null && !t.done ? dueLabel(t.dueAt, now) : null;
  return (
    <div className={`todo${t.done ? ' done' : ''}${selected ? ' selected' : ''}`}>
      <Checkbox done={t.done} onToggle={() => toggleTodo(t.id)} label={t.title} />
      <button className="todo-body" onClick={onSelect} tabIndex={onSelect ? 0 : -1}>
        <span className="todo-title">{t.title}</span>
        <span className="todo-sub">
          <AreaDot area={t.area} />
          {t.source.label}
          {t.nudges > 0 && !t.done && <span className="todo-nudge">· 催过 {t.nudges} 次</span>}
          {t.proposed && !t.done && <span className="todo-proposed">· 时间是建议的</span>}
        </span>
      </button>
      <span className="todo-when">
        {plan && <span className="todo-plan">{plan}</span>}
        {due && <span className={`todo-due ${due.level}`}>{due.text}</span>}
      </span>
      {t.proposed && !t.done && (
        <button className="btn sm" onClick={() => confirmTodo(t.id)}>
          确认
        </button>
      )}
    </div>
  );
}

const answer = (ask: Ask, value: string) => {
  answerAsk(ask, value);
  if (ask.kind === 'takeover' && value === 'go') go(`desktop-${ask.botId}`);
};

/** A one-line ask for Today: the question, who asks, and at most two ways to answer. */
export function AskRow({ ask, state, now }: { ask: Ask; state: AppState; now: number }) {
  const bot = state.bots.find((b) => b.id === ask.botId);
  const primary = ask.options.find((o) => o.primary) ?? ask.options[0];
  const needsDetail = !!ask.preview;
  return (
    <li className="ask-row">
      <Avatar bot={bot} size={26} />
      <div className="ask-row-main">
        <div className="ask-row-title">{ask.title}</div>
        <div className="ask-row-sub">
          {bot?.name} · {ago(ask.at, now)}
          {ask.preview && ` · ${ask.preview.label}`}
        </div>
      </div>
      <div className="ask-row-actions">
        {needsDetail ? (
          <a className="btn sm primary" href="#confirm">
            看一下
          </a>
        ) : (
          <>
            <button className="btn sm primary" onClick={() => answer(ask, primary.value)}>
              {primary.label}
            </button>
            {ask.options.length > 1 && (
              <a className="btn sm" href="#confirm">
                其他
              </a>
            )}
          </>
        )}
      </div>
    </li>
  );
}

/** The full ask, with the preview and every option. */
export function AskCard({ ask, state, now }: { ask: Ask; state: AppState; now: number }) {
  const bot = state.bots.find((b) => b.id === ask.botId);
  return (
    <article className={`ask-card ${ask.kind}`}>
      <div className="ask-card-head">
        <Avatar bot={bot} size={22} />
        <span className="ask-card-who">{bot?.name}</span>
        <span className="ask-card-time">{ago(ask.at, now)}</span>
      </div>
      <div className="ask-card-title">{ask.title}</div>
      {ask.detail && <p className="ask-card-detail">{ask.detail}</p>}
      {ask.preview && (
        <div className="ask-card-preview">
          <div className="ask-card-preview-label">{ask.preview.label}</div>
          <div className="ask-card-preview-body">{ask.preview.body}</div>
        </div>
      )}
      <div className="ask-card-actions">
        {ask.options.map((o) => (
          <button key={o.value} className={`btn${o.primary ? ' primary' : ''}${o.danger ? ' danger' : ''}`} onClick={() => answer(ask, o.value)}>
            {o.label}
          </button>
        ))}
      </div>
    </article>
  );
}
