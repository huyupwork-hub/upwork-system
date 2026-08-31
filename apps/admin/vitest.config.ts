import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    environment: 'node',
    include: ['test/**/*.test.ts', 'test/**/*.test.tsx'],
  },
  esbuild: { jsx: 'automatic' },
  resolve: { alias: { '@': new URL('./src/', import.meta.url).pathname } },
});
