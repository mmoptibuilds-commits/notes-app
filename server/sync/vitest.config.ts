import { defineConfig } from 'vitest/config';
export default defineConfig({define:{__TEST_BUILD__:'true'},test:{include:['test/**/*.test.ts'],exclude:['dist/**','node_modules/**']}});
