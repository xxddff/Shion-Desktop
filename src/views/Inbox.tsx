import { CircleCheck, CircleHelp, KeyRound, ShieldAlert } from 'lucide-react';
import { useState } from 'react';
import { Toolbar } from '../components/Shell';
import type { AppState, InboxRequest } from '../data/model';
import { answerRequest } from '../data/store';
import { Avatar } from '../ui/bits';
import { ago, useNow } from '../ui/format';

/**
 * Server→client JSON-RPC requests (approval / clarify / secret) from every
 * attached session, in one queue. Each answer is a JSON-RPC response that
 * echoes the request's string id.
 */
export function InboxView({ state }: { state: AppState }) {
  const now = useNow();
  return (
    <>
      <Toolbar title="待处理" sub="Bot 发来的审批、提问和密钥请求，回复后它们会继续工作" />
      <div className="view">
        <div className="pad">
          {state.inbox.length === 0 ? (
            <div className="panel empty" style={{ maxWidth: 820 }}>
              <CircleCheck size={26} color="var(--good)" />
              <strong>没有待处理的请求</strong>
              <span>Bot 需要批准危险命令、向你提问或索要密钥时，会出现在这里，同时发系统通知。</span>
            </div>
          ) : (
            <div className="inbox-list">
              {state.inbox.map((r) => (
                <RequestCard key={r.rpcId} req={r} state={state} now={now} />
              ))}
            </div>
          )}
        </div>
      </div>
    </>
  );
}

export function RequestCard({ req, state, now, inline = false }: { req: InboxRequest; state: AppState; now: number; inline?: boolean }) {
  const bot = state.bots.find((b) => b.id === req.botId);
  const session = state.sessions[req.sessionId];
  const [text, setText] = useState('');
  const Icon = req.method === 'approval' ? ShieldAlert : req.method === 'clarify' ? CircleHelp : KeyRound;
  const label = { approval: '命令审批', clarify: '提问', secret: '密钥' }[req.method];

  return (
    <article className={`panel req ${req.method}${inline ? ' inline-req' : ''}`}>
      <div className="top">
        <Avatar bot={bot} size={24} />
        <strong>{bot?.displayName}</strong>
        <span className={`pill ${req.method === 'approval' ? 'tone-warning' : 'tone-info'}`}>
          <Icon size={11} />
          {label}
        </span>
        <span className="ctx">
          <a href={`#bot-${req.botId}`}>
            {session?.title}
          </a>{' '}
          · {ago(req.at, now)}
        </span>
      </div>

      {req.method === 'approval' && req.approval && (
        <>
          <div className="q">{req.approval.description}</div>
          <div className="cmd">{req.approval.command}</div>
          <div className="actions">
            <button className="btn primary" onClick={() => answerRequest(req, { choice: 'once' })}>
              批准一次
            </button>
            <button className="btn" onClick={() => answerRequest(req, { choice: 'session' })}>
              本会话内允许
            </button>
            <button className="btn" onClick={() => answerRequest(req, { choice: 'always' })}>
              总是允许
            </button>
            <button className="btn danger" onClick={() => answerRequest(req, { choice: 'deny' })}>
              拒绝
            </button>
            <span className="faint mono" style={{ marginLeft: 'auto', fontSize: 11 }}>
              id {req.rpcId}
            </span>
          </div>
        </>
      )}

      {req.method === 'clarify' && req.clarify && (
        <>
          <div className="q">{req.clarify.question}</div>
          <div className="actions">
            {req.clarify.options.map((o) => (
              <button key={o} className="btn" onClick={() => answerRequest(req, { answer: o })}>
                {o}
              </button>
            ))}
          </div>
          <form
            className="actions"
            onSubmit={(e) => {
              e.preventDefault();
              if (text.trim()) answerRequest(req, { answer: text.trim() });
            }}
          >
            <input
              id={`clarify-${req.rpcId}`}
              className="field"
              style={{ flex: 1, minWidth: 160 }}
              placeholder="或者自己写回答…"
              value={text}
              onChange={(e) => setText(e.target.value)}
            />
            <button className="btn primary" type="submit" disabled={!text.trim()}>
              回答
            </button>
            <button className="btn ghost" type="button" onClick={() => answerRequest(req, {})}>
              跳过
            </button>
          </form>
        </>
      )}

      {req.method === 'secret' && req.secret && (
        <>
          <div className="q">{req.secret.prompt}</div>
          <form
            className="actions"
            onSubmit={(e) => {
              e.preventDefault();
              if (text) answerRequest(req, { value: '••••' });
            }}
          >
            <span className="chip mono">{req.secret.name}</span>
            <input
              id={`secret-${req.rpcId}`}
              className="field"
              type="password"
              autoComplete="off"
              style={{ flex: 1, minWidth: 160 }}
              placeholder="粘贴值，只发给这个 Bot，不会保存在 Shion"
              value={text}
              onChange={(e) => setText(e.target.value)}
            />
            <button className="btn primary" type="submit" disabled={!text}>
              提交
            </button>
          </form>
        </>
      )}
    </article>
  );
}
