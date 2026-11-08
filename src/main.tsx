import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { App } from './App';
import './styles.css';

// Inside the Tauri shell the native window supplies chrome and vibrancy.
if ('__TAURI_INTERNALS__' in window) document.documentElement.classList.add('is-tauri');

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
