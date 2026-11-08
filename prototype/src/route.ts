/** Hash routes (ASCII letters, digits and hyphens only). */
export type Route =
  | { view: 'today' }
  | { view: 'todos'; tab: 'mine' | 'delegated' }
  | { view: 'calendar' }
  | { view: 'reports'; kind: 'study' | 'work' | 'life' | 'news' }
  | { view: 'confirm' }
  | { view: 'chat'; botId: string };

export function parseHash(hash: string): Route {
  const h = hash.replace(/^#/, '');
  if (h === 'todos') return { view: 'todos', tab: 'mine' };
  if (h === 'todos-delegated') return { view: 'todos', tab: 'delegated' };
  if (h === 'calendar') return { view: 'calendar' };
  if (h === 'confirm') return { view: 'confirm' };
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
