import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// Relative base so the same build works on any GitHub Pages path; routing is hash-based.
export default defineConfig({ base: './', plugins: [react()], build: { sourcemap: false }, test: { environment: 'node' } });
