// @ts-check
import { defineConfig } from 'astro/config';

export default defineConfig({
  site: 'https://open-audio-analyzer.com',
  output: 'static',
  trailingSlash: 'never',
  build: { format: 'file', inlineStylesheets: 'always' },
  compressHTML: true,
  devToolbar: { enabled: false },
});
