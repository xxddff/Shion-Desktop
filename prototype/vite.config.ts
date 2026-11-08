import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// UI prototype only; the shipping app is SwiftUI (see ../README.md).
export default defineConfig({
  plugins: [react()],
  server: { port: 1420 },
  build: { target: 'safari15', outDir: 'dist' },
});
