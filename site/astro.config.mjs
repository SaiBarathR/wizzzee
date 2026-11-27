// @ts-check
import { defineConfig } from 'astro/config';
import { rehypeHeadingIds, unified } from '@astrojs/markdown-remark';
import { rehypeWizzzee } from './src/lib/rehype-wizzzee.mjs';
import { codeThemes } from './src/lib/code-themes.mjs';

// GitHub Pages project site: every URL lives under /wizzzee/.
export default defineConfig({
  site: 'https://saibarathr.github.io',
  base: '/wizzzee',
  trailingSlash: 'always',
  // Astro's HTML compression drops the space between a line of text and an inline element on the next line.
  compressHTML: false,
  build: { format: 'directory', inlineStylesheets: 'auto' },
  markdown: {
    shikiConfig: {
      themes: codeThemes,
      defaultColor: false,
      wrap: false,
    },
    processor: unified({ rehypePlugins: [rehypeHeadingIds, rehypeWizzzee] }),
  },
  vite: {
    // docs/ and Resources/Info.plist live outside site/.
    server: { fs: { allow: ['..'] } },
  },
});
