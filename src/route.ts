/**
 * Hash routes. Names stay within ASCII letters, digits and hyphens so they
 * survive being shared as links; task ids drop their `t_` prefix.
 */
export type Route =
  | { view: 'overview' }
  | { view: 'inbox' }
  | { view: 'bots' }
  | { view: 'bot'; id: string }
  | { view: 'board'; slug: string; taskId?: string };

export function parseHash(hash: string, taskBoard: (taskId: string) => string | undefined): Route {
  const h = hash.replace(/^#/, '');
  if (h === 'inbox') return { view: 'inbox' };
  if (h === 'bots') return { view: 'bots' };
  if (h.startsWith('bot-')) return { view: 'bot', id: h.slice(4) };
  if (h.startsWith('board-')) return { view: 'board', slug: h.slice(6) };
  if (h.startsWith('task-')) {
    const taskId = `t_${h.slice(5)}`;
    return { view: 'board', slug: taskBoard(taskId) ?? 'default', taskId };
  }
  return { view: 'overview' };
}

export const taskHref = (taskId: string) => `#task-${taskId.replace(/^t_/, '')}`;
