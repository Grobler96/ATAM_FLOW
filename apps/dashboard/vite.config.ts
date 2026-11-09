import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// Relative base so the same build works on any GitHub Pages path; routing is hash-based.
// Two pages: the internal command centre (index.html) and the separate decorator portal (portal.html).
export default defineConfig({
  base: './', plugins: [react()], test: { environment: 'node' },
  build: { sourcemap: false, rollupOptions: { input: { main: new URL('./index.html', import.meta.url).pathname, portal: new URL('./portal.html', import.meta.url).pathname } } }
});
