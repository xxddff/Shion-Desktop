/** Hash routes (ASCII letters, digits and hyphens only). */
export type Route =
  | { view: 'today' }
  | { view: 'todos' }
  | { view: 'board'; cardId?: string }
  | { view: 'work'; cardId: string }
  | { view: 'calendar' }
  | { view: 'reports'; kind: 'study' | 'work' | 'life' | 'news' }
  | { view: 'confirm' }
  | { view: 'desktop'; botId?: string }
  | { view: 'chat'; botId: string };

export function parseHash(hash: string): Route {
  const h = hash.replace(/^#/, '');
  if (h === 'todos') return { view: 'todos' };
  if (h === 'board' || h === 'todos-delegated') return { view: 'board' };
  if (h.startsWith('card-')) return { view: 'board', cardId: `t_${h.slice(5)}` };
  if (h.startsWith('work-')) return { view: 'work', cardId: `t_${h.slice(5)}` };
  if (h === 'calendar') return { view: 'calendar' };
  if (h === 'confirm') return { view: 'confirm' };
  if (h === 'desktop') return { view: 'desktop' };
  if (h.startsWith('desktop-')) return { view: 'desktop', botId: h.slice(8) };
  if (h.startsWith('reports')) {
    const k = h.slice(8);
    return { view: 'reports', kind: k === 'work' || k === 'life' || k === 'news' ? k : 'study' };
  }
  if (h.startsWith('chat-')) return { view: 'chat', botId: h.slice(5) };
  return { view: 'today' };
}

export const go = (hash: string) => {
  location.hash = hash;
};
