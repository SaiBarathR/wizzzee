import type { APIRoute } from 'astro';

const pages = ['', 'download/', 'docs/', 'docs/using-wizzzee/', 'docs/search/', 'docs/reading-the-numbers/', 'docs/command-line/', 'docs/how-it-works/', 'changelog/'];

export const GET: APIRoute = ({ site }) => {
  const base = new URL(import.meta.env.BASE_URL.replace(/\/?$/, '/'), site);
  const urls = pages.map((p) => `  <url><loc>${new URL(p, base).href}</loc></url>`).join('\n');
  const xml = `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls}\n</urlset>\n`;
  return new Response(xml, { headers: { 'Content-Type': 'application/xml' } });
};
