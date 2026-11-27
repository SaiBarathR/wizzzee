// Rehype plugin for every Markdown file the site renders (docs/cli.md, docs/architecture.md, docs/releases/*.md,
// the guides):
//  - adds a "#" anchor link to h2–h4 (ids come from rehypeHeadingIds, which runs first)
//  - demotes headings in release notes by one level (their "# Wizzzee 0.6.2" sits under the page's h1), and prefixes
//    their ids with the version: every release note is on the one changelog page, and they share headings
//  - points relative links to repository files at GitHub, and links between docs at their pages
//  - makes tables scroll horizontally on narrow screens instead of overflowing
const REPO = 'https://github.com/SaiBarathR/wizzzee/blob/main/';
const BASE = '/wizzzee/';

function walk(node, fn, parent = null, index = 0) {
  fn(node, parent, index);
  if (node.children) {
    // copy: fn may replace children
    node.children.slice().forEach((child) => walk(child, fn, node, node.children.indexOf(child)));
  }
}

const docPages = {
  'getting-started.md': 'docs/',
  'using-wizzzee.md': 'docs/using-wizzzee/',
  'search.md': 'docs/search/',
  'reading-the-numbers.md': 'docs/reading-the-numbers/',
  'cli.md': 'docs/command-line/',
  'architecture.md': 'docs/how-it-works/',
};

export function rehypeWizzzee() {
  return (tree, file) => {
    const path = String(file?.path || file?.history?.[0] || '');
    const isRelease = /[\\/]docs[\\/]releases[\\/]/.test(path);
    const version = isRelease ? (path.match(/([^\\/]+)\.md$/)?.[1] ?? '') : '';
    const sourceDir = isRelease ? 'docs/releases/' : /[\\/]docs[\\/][^\\/]+\.md$/.test(path) ? 'docs/' : '';

    walk(tree, (node, parent, index) => {
      if (node.type !== 'element') return;

      if (isRelease && /^h[1-5]$/.test(node.tagName)) {
        node.tagName = 'h' + (Number(node.tagName[1]) + 1);
        if (node.properties?.id) node.properties.id = `${version}-${node.properties.id}`;
      }

      if (/^h[2-4]$/.test(node.tagName) && node.properties?.id) {
        node.children.push({
          type: 'element',
          tagName: 'a',
          properties: { className: ['anchor'], href: '#' + node.properties.id, ariaLabel: 'Link to this section' },
          children: [{ type: 'text', value: '#' }],
        });
      }

      if (node.tagName === 'a' && typeof node.properties?.href === 'string') {
        const href = node.properties.href;
        // (The heading anchors added above already carry the prefixed id.)
        if (isRelease && href.startsWith('#') && href.length > 1 && !node.properties.className?.includes('anchor')) {
          node.properties.href = `#${version}-${href.slice(1)}`;
          return;
        }
        if (/^[a-z]+:/i.test(href) || href.startsWith('#') || href.startsWith('/')) {
          if (/^https?:/i.test(href)) node.properties.rel = ['noopener'];
          return;
        }
        const [target, hash = ''] = href.split('#');
        const name = target.split('/').pop();
        if (docPages[name]) {
          node.properties.href = BASE + docPages[name] + (hash ? '#' + hash : '');
        } else {
          // Resolve "../README.md" and "./x" against the source file's folder.
          const parts = (sourceDir + target).split('/');
          const out = [];
          for (const p of parts) {
            if (p === '..') out.pop();
            else if (p !== '.' && p !== '') out.push(p);
          }
          node.properties.href = REPO + out.join('/') + (hash ? '#' + hash : '');
        }
      }

      // An empty header cell still needs a name for screen readers.
      if (node.tagName === 'th' && !node.children.some((c) => c.type !== 'text' || c.value.trim())) {
        node.children = [{ type: 'element', tagName: 'span', properties: { className: ['visually-hidden'] }, children: [{ type: 'text', value: 'Description' }] }];
      }

      if (node.tagName === 'table' && parent && parent.tagName !== 'div') {
        parent.children[index] = {
          type: 'element',
          tagName: 'div',
          properties: { className: ['table-wrap'], tabIndex: 0 },
          children: [node],
        };
      }
    });
  };
}
