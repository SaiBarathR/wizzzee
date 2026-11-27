// Draws the site's mark: the app icon (scripts/make-icon.swift) as a flat SVG — the same squarified tiles in the
// same colours on the dark plate, without the macOS canvas margin and without the plate's gradient.
// Writes public/favicon.svg, which is also the mark in the header, footer and download card.   node scripts/make-mark.mjs
import fs from 'node:fs';

const weights = [30, 18, 12, 9, 7, 6, 5, 4, 3, 2.5, 2, 1.6, 1.2];
const palette = [
  [0.91, 0.58, 0.2], [0.3, 0.68, 0.31], [0.86, 0.24, 0.31], [0.24, 0.47, 0.78], [0.94, 0.78, 0.2],
  [0.78, 0.31, 0.63], [0.19, 0.69, 0.66], [0.55, 0.31, 0.78], [0.78, 0.8, 0.2], [0.25, 0.75, 0.88],
  [0.85, 0.42, 0.35], [0.35, 0.55, 0.24], [0.63, 0.44, 0.25],
];

// The icon's squarify, in its y-up coordinates.
function squarify(areas, rect) {
  const out = areas.map(() => null);
  const total = areas.reduce((a, b) => a + b, 0);
  const scale = (rect.w * rect.h) / total;
  let free = { ...rect };
  let i = 0;
  const worst = (sum, lo, hi, side) => (sum > 0 && lo > 0 ? Math.max((side * side * hi) / (sum * sum), (sum * sum) / (side * side * lo)) : Infinity);
  while (i < areas.length) {
    const side = Math.min(free.w, free.h);
    if (side <= 0) break;
    let sum = 0, count = 0, best = Infinity, lo = Number.MAX_VALUE, hi = 0;
    while (i + count < areas.length) {
      const a = areas[i + count] * scale;
      const w = worst(sum + a, Math.min(lo, a), Math.max(hi, a), side);
      if (count > 0 && w > best) break;
      sum += a; lo = Math.min(lo, a); hi = Math.max(hi, a); best = w; count++;
    }
    const t = sum / side;
    if (free.w <= free.h) {
      let x = free.x;
      for (let k = 0; k < count; k++) { const w = (areas[i + k] * scale) / t; out[i + k] = { x, y: free.y, w, h: t }; x += w; }
      free = { x: free.x, y: free.y + t, w: free.w, h: free.h - t };
    } else {
      let y = free.y;
      for (let k = 0; k < count; k++) { const h = (areas[i + k] * scale) / t; out[i + k] = { x: free.x, y, w: t, h }; y += h; }
      free = { x: free.x + t, y: free.y, w: free.w - t, h: free.h };
    }
    i += count;
  }
  return out;
}

const S = 1024;
const plate = { x: S * 0.09, y: S * 0.09, w: S * 0.82, h: S * 0.82 };
const radius = plate.w * 0.185;
const inset = plate.w * 0.115;
const field = { x: plate.x + inset, y: plate.y + inset, w: plate.w - 2 * inset, h: plate.h - 2 * inset };
const gap = S * 0.006;
const hex = (c) => '#' + c.map((v) => Math.round(v * 255).toString(16).padStart(2, '0')).join('');
const r1 = (n) => Math.round(n * 10) / 10;

let tiles = '';
squarify(weights, field).forEach((t, i) => {
  const d = { x: t.x + gap, y: t.y + gap, w: t.w - 2 * gap, h: t.h - 2 * gap };
  if (d.w <= 0 || d.h <= 0) return;
  const top = S - (d.y + d.h); // flip to y-down
  const c = Math.min(d.w, d.h) * 0.14;
  tiles += `<rect x="${r1(d.x)}" y="${r1(top)}" width="${r1(d.w)}" height="${r1(d.h)}" rx="${r1(c)}" fill="${hex(palette[i % palette.length])}"/>`;
  if (d.h > S * 0.05) {
    // The icon's soft top highlight: the top 32% of the tile, lightened.
    const id = `h${i}`;
    tiles += `<clipPath id="${id}"><rect x="${r1(d.x)}" y="${r1(top)}" width="${r1(d.w)}" height="${r1(d.h)}" rx="${r1(c)}"/></clipPath>`;
    tiles += `<rect clip-path="url(#${id})" x="${r1(d.x)}" y="${r1(top)}" width="${r1(d.w)}" height="${r1(d.h * 0.32)}" fill="#fff" fill-opacity=".16"/>`;
  }
});

const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="${r1(plate.x)} ${r1(plate.y)} ${r1(plate.w)} ${r1(plate.h)}"><rect x="${r1(plate.x)}" y="${r1(plate.y)}" width="${r1(plate.w)}" height="${r1(plate.h)}" rx="${r1(radius)}" fill="#1f232a"/>${tiles}</svg>\n`;
fs.writeFileSync('public/favicon.svg', svg);
console.log('wrote public/favicon.svg');
