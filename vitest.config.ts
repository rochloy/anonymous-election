import { defineConfig } from 'vitest/config';
import path from 'path';

export default defineConfig({
  test: {
    environment: 'node',
    include: [
      'rate-limit-policy.test.ts',
      'safe-log.test.ts',
      'wipe-confirmation.test.ts',
      'datetime-local.test.ts',
      'adjudication-export-regressions.test.ts',
    ],
    clearMocks: true,
  },
  resolve: {
    alias: {
      '@': path.resolve(__dirname, '.'),
    },
  },
});
