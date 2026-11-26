import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// One id per build. The page carries it (as __BUILD_ID__) and the build also publishes it as version.json, so an open page can tell when a newer build has been published.
const BUILD_ID = `${new Date().toISOString().replace(/\D/g, '').slice(0, 14)}-${(process.env.GITHUB_SHA ?? 'local').slice(0, 7)}`;
const publishVersion = () => ({ name: 'publish-version', generateBundle() { this.emitFile({ type: 'asset', fileName: 'version.json', source: JSON.stringify({ build: BUILD_ID }) }); } });

// Relative base so the same build works on any GitHub Pages path; routing is hash-based.
// Two pages: the internal command centre (index.html) and the separate decorator portal (portal.html).
export default defineConfig({
  base: './', plugins: [react(), publishVersion()], test: { environment: 'node' }, define: { __BUILD_ID__: JSON.stringify(BUILD_ID) },
  build: { sourcemap: false, rollupOptions: { input: { main: new URL('./index.html', import.meta.url).pathname, portal: new URL('./portal.html', import.meta.url).pathname } } }
});
