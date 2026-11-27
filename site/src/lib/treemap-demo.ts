// The treemap on the home page. A port of the app's own TreemapLayout (squarified tiles carrying van Wijk cushion
// coefficients) and TreemapRenderer (per-pixel lighting), with the same constants and the same palette, so the
// shading looks like Wizzzee's. Interaction follows the app: hover names a tile, click selects it, double-click
// zooms to the folder, the path above zooms back out, and a file type in the list sets every other type back.
import { buildDemoDisk, formatBytes, pathOf, type DemoNode } from './demo-disk';

// ---------- palette (TreemapPalette.swift) ----------
const PALETTE: [number, number, number][] = [
  [0.91, 0.58, 0.2], [0.3, 0.68, 0.31], [0.86, 0.24, 0.31], [0.24, 0.47, 0.78], [0.94, 0.78, 0.2], [0.78, 0.31, 0.63],
  [0.19, 0.69, 0.66], [0.55, 0.31, 0.78], [0.78, 0.8, 0.2], [0.25, 0.75, 0.88], [0.85, 0.42, 0.35], [0.35, 0.55, 0.24],
  [0.63, 0.44, 0.25], [0.94, 0.51, 0.69], [0.31, 0.35, 0.75], [0.2, 0.63, 0.44], [0.72, 0.62, 0.24], [0.6, 0.24, 0.4],
  [0.44, 0.69, 0.87], [0.44, 0.8, 0.62], [0.64, 0.38, 0.64], [0.87, 0.66, 0.44], [0.48, 0.52, 0.6], [0.36, 0.42, 0.47],
];
const OVERFLOW: [number, number, number] = [0.45, 0.47, 0.5];
const COLLAPSED: [number, number, number] = [0.38, 0.42, 0.48];
const rgbOf = (i: number) => (i >= 0 && i < PALETTE.length ? PALETTE[i] : OVERFLOW);
const css = (c: [number, number, number]) => `rgb(${Math.round(c[0] * 255)} ${Math.round(c[1] * 255)} ${Math.round(c[2] * 255)})`;

// ---------- layout (TreemapLayout.swift) ----------
const MIN_SUBDIVIDE = 5;
const MIN_CELL = 0.7;
const MAX_DEPTH = 12;
const CUSHION_HEIGHT = 0.3;
const INHERITED_DAMPING = 0.3;

interface Rect { x: number; y: number; w: number; h: number; }
interface Cell { r: Rect; node: DemoNode; color: number; sx1: number; sx2: number; sy1: number; sy2: number; }
interface Frame { r: Rect; node: DemoNode; depth: number; }

function squarify(areas: number[], rect: Rect): Rect[] {
  const out: Rect[] = areas.map(() => ({ x: 0, y: 0, w: 0, h: 0 }));
  const total = areas.reduce((a, b) => a + b, 0);
  if (total <= 0 || rect.w <= 0 || rect.h <= 0) return out;
  const scale = (rect.w * rect.h) / total;
  let free = { ...rect };
  let i = 0;
  const worst = (sum: number, lo: number, hi: number, side: number) =>
    sum > 0 && lo > 0 ? Math.max((side * side * hi) / (sum * sum), (sum * sum) / (side * side * lo)) : Infinity;
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
    const t = side > 0 ? sum / side : 0;
    if (free.w <= free.h) {
      let x = free.x;
      for (let k = 0; k < count; k++) {
        const w = t > 0 ? (areas[i + k] * scale) / t : 0;
        out[i + k] = { x, y: free.y, w, h: t };
        x += w;
      }
      free = { x: free.x, y: free.y + t, w: free.w, h: Math.max(0, free.h - t) };
    } else {
      let y = free.y;
      for (let k = 0; k < count; k++) {
        const h = t > 0 ? (areas[i + k] * scale) / t : 0;
        out[i + k] = { x: free.x, y, w: t, h };
        y += h;
      }
      free = { x: free.x + t, y: free.y, w: Math.max(0, free.w - t), h: free.h };
    }
    i += count;
  }
  return out;
}

function ridge(lo: number, hi: number, s: [number, number]) {
  const span = hi - lo;
  if (span <= 0) return;
  s[0] += (4 * CUSHION_HEIGHT * (hi + lo)) / span;
  s[1] -= (4 * CUSHION_HEIGHT) / span;
}

function layout(root: DemoNode, w: number, h: number, colorOf: Map<string, number>) {
  const cells: Cell[] = [];
  const frames: Frame[] = [{ r: { x: 0, y: 0, w, h }, node: root, depth: 0 }];
  const sub = (dir: DemoNode, r: Rect, depth: number, sx1: number, sx2: number, sy1: number, sy2: number) => {
    const kids = (dir.children ?? []).filter((c) => c.size > 0).sort((a, b) => b.size - a.size);
    if (!kids.length) return;
    const rects = squarify(kids.map((k) => k.size), r);
    kids.forEach((k, idx) => {
      const cr = rects[idx];
      if (cr.w < MIN_CELL || cr.h < MIN_CELL) return;
      const x: [number, number] = [sx1 * INHERITED_DAMPING, sx2 * INHERITED_DAMPING];
      const y: [number, number] = [sy1 * INHERITED_DAMPING, sy2 * INHERITED_DAMPING];
      ridge(cr.x, cr.x + cr.w, x);
      ridge(cr.y, cr.y + cr.h, y);
      if (k.children) {
        if (depth < MAX_DEPTH && cr.w >= MIN_SUBDIVIDE && cr.h >= MIN_SUBDIVIDE) {
          frames.push({ r: cr, node: k, depth: depth + 1 });
          const inner = { x: cr.x + 1, y: cr.y + 1, w: cr.w - 2, h: cr.h - 2 };
          if (inner.w > MIN_CELL && inner.h > MIN_CELL) {
            sub(k, inner, depth + 1, x[0], x[1], y[0], y[1]);
            return;
          }
        }
        cells.push({ r: cr, node: k, color: -1, sx1: x[0], sx2: x[1], sy1: y[0], sy2: y[1] });
      } else {
        cells.push({ r: cr, node: k, color: colorOf.get(k.ext ?? '') ?? PALETTE.length, sx1: x[0], sx2: x[1], sy1: y[0], sy2: y[1] });
      }
    });
  };
  sub(root, { x: 0, y: 0, w, h }, 0, 0, 0, 0, 0);
  return { cells, frames };
}

// ---------- renderer (TreemapRenderer.swift) ----------
const LIGHT = (() => { const v = [-0.42, -0.52, 1]; const l = Math.hypot(v[0], v[1], v[2]); return v.map((n) => n / l); })();
const AMBIENT = 0.47, DIFFUSE = 0.64, MAX_INTENSITY = 1.22, EDGE_SHADE = 0.62;
const SET_BACK_GREY = 0.8, SET_BACK_LIGHT = 0.3;

function setBack(c: [number, number, number]): [number, number, number] {
  const g = 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2];
  return c.map((ch) => (ch + (g - ch) * SET_BACK_GREY) * SET_BACK_LIGHT) as [number, number, number];
}

function render(img: ImageData, cells: Cell[], scale: number, focus: number | null) {
  const { width, height, data } = img;
  const buf = new Uint32Array(data.buffer);
  buf.fill(0xff14110f); // #0f1114, little-endian ABGR
  const inv = 1 / scale;
  const edge = Math.max(1, Math.round(scale));
  for (const c of cells) {
    let base = c.color < 0 ? COLLAPSED : rgbOf(c.color);
    if (focus !== null && c.color !== focus) base = setBack(base);
    const x0 = Math.max(0, Math.floor(c.r.x * scale));
    const x1 = Math.min(width, Math.max(x0 + 1, Math.ceil((c.r.x + c.r.w) * scale)));
    const y0 = Math.max(0, Math.floor(c.r.y * scale));
    const y1 = Math.min(height, Math.max(y0 + 1, Math.ceil((c.r.y + c.r.h) * scale)));
    if (x0 >= x1 || y0 >= y1) continue;
    const insetX = x1 - x0 > edge * 3;
    const insetY = y1 - y0 > edge * 3;
    const r = base[0] * 255, g = base[1] * 255, b = base[2] * 255;
    for (let py = y0; py < y1; py++) {
      const y = (py + 0.5) * inv;
      const ny = -(2 * c.sy2 * y + c.sy1);
      const row = py * width;
      const onEdgeY = insetY && (py - y0 < edge || y1 - py <= edge);
      for (let px = x0; px < x1; px++) {
        const x = (px + 0.5) * inv;
        const nx = -(2 * c.sx2 * x + c.sx1);
        const dot = (nx * LIGHT[0] + ny * LIGHT[1] + LIGHT[2]) / Math.sqrt(nx * nx + ny * ny + 1);
        let k = Math.min(MAX_INTENSITY, AMBIENT + DIFFUSE * Math.max(0, dot));
        if (onEdgeY || (insetX && (px - x0 < edge || x1 - px <= edge))) k *= EDGE_SHADE;
        const R = Math.min(255, r * k) | 0, G = Math.min(255, g * k) | 0, B = Math.min(255, b * k) | 0;
        buf[row + px] = 0xff000000 | (B << 16) | (G << 8) | R;
      }
    }
  }
}

// ---------- the widget ----------
interface TypeRow { ext: string; size: number; count: number; color: number; }

export function mountTreemapDemo(rootEl: HTMLElement) {
  const canvas = rootEl.querySelector<HTMLCanvasElement>('canvas.tm-map')!;
  const overlay = rootEl.querySelector<HTMLCanvasElement>('canvas.tm-overlay')!;
  const stage = rootEl.querySelector<HTMLElement>('.tm-stage')!;
  const crumbs = rootEl.querySelector<HTMLElement>('.tm-crumbs')!;
  const tip = rootEl.querySelector<HTMLElement>('.tm-tip')!;
  const statusText = rootEl.querySelector<HTMLElement>('.tm-status-text')!;
  const zoomIn = rootEl.querySelector<HTMLButtonElement>('[data-zoom-in]')!;
  const zoomOut = rootEl.querySelector<HTMLButtonElement>('[data-zoom-out]')!;
  const typeList = rootEl.querySelector<HTMLElement>('.tm-types-list')!;
  const typeHead = rootEl.querySelector<HTMLElement>('.tm-types-count')!;
  const focusLabel = rootEl.querySelector<HTMLElement>('.tm-focus')!;
  const live = rootEl.querySelector<HTMLElement>('.tm-live')!;
  const ctx = canvas.getContext('2d')!;
  const octx = overlay.getContext('2d')!;

  const disk = buildDemoDisk();

  // Rank extensions by total size across the whole disk, as the app does at the end of a scan: the rank is the
  // colour, so the biggest types get the most separable hues and the rest fall through to grey.
  const byExt = new Map<string, { size: number; count: number }>();
  (function walk(n: DemoNode) {
    if (n.children) n.children.forEach(walk);
    else {
      const e = byExt.get(n.ext ?? '') ?? { size: 0, count: 0 };
      e.size += n.size; e.count++;
      byExt.set(n.ext ?? '', e);
    }
  })(disk);
  const types: TypeRow[] = [...byExt.entries()].sort((a, b) => b[1].size - a[1].size).map(([ext, v], i) => ({ ext, ...v, color: i }));
  const colorOf = new Map(types.map((t) => [t.ext, t.color]));
  const extLabel = (e: string) => (e ? '.' + e : '(no ext)');

  let root: DemoNode = disk;
  let cells: Cell[] = [];
  let frames: Frame[] = [];
  let selected: DemoNode | null = null;
  let hovered: Cell | null = null;
  let focus: number | null = null;
  let size = { w: 0, h: 0, scale: 1 };

  const cellAt = (x: number, y: number) => {
    for (let i = cells.length - 1; i >= 0; i--) {
      const r = cells[i].r;
      if (x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h) return cells[i];
    }
    return null;
  };
  const frameAt = (x: number, y: number) => {
    let best: Frame | null = null;
    for (const f of frames) if (x >= f.r.x && x < f.r.x + f.r.w && y >= f.r.y && y < f.r.y + f.r.h && (!best || f.depth > best.depth)) best = f;
    return best;
  };
  const isInside = (n: DemoNode | null, dir: DemoNode) => { for (let a = n; a; a = a.parent ?? null) if (a === dir) return true; return false; };
  /** The disk by name, anything else by its path. */
  const where = (n: DemoNode) => (n === disk ? disk.name : pathOf(n));

  function drawLabels() {
    ctx.save();
    ctx.scale(size.scale, size.scale);
    ctx.textBaseline = 'top';
    ctx.shadowColor = 'rgba(0,0,0,0.9)';
    ctx.shadowBlur = 2.5 * size.scale;
    ctx.fillStyle = 'rgba(255,255,255,0.96)';
    const line = 13, insetX = 12, insetTop = 8, trailing = 4;
    const placed: Rect[] = [];
    const hit = (a: Rect) => placed.some((b) => a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h);
    for (const f of frames) {
      if (f.depth === 0 || f.depth > 4) continue;
      if (f.r.w < 62 || f.r.h < insetTop + line) continue;
      ctx.font = `500 ${f.depth === 1 ? 10.5 : 9.5}px -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", Roboto, sans-serif`;
      let text = `${f.node.name} (${formatBytes(f.node.size)})`;
      const room = f.r.w - insetX - trailing;
      if (ctx.measureText(text).width > room) {
        while (text.length > 1 && ctx.measureText(text + '…').width > room) text = text.slice(0, -1);
        text += '…';
      }
      const box = { x: f.r.x + insetX, y: f.r.y + insetTop, w: Math.min(ctx.measureText(text).width + 2, room), h: line };
      let tries = 0;
      while (hit(box) && tries < 3) { box.y += line; tries++; }
      if (box.y + box.h > f.r.y + f.r.h || hit(box)) continue;
      placed.push({ x: box.x - 2, y: box.y - 1, w: box.w + 4, h: box.h + 2 });
      ctx.fillText(text, box.x, box.y);
    }
    ctx.restore();
  }

  // White hairlines round folder groups, fading with depth (TreemapView.drawGroupBorders).
  function drawGroupBorders() {
    ctx.save();
    ctx.scale(size.scale, size.scale);
    for (const f of frames) {
      if (f.depth === 0 || f.depth > 6 || f.r.w <= 3 || f.r.h <= 3) continue;
      ctx.strokeStyle = `rgba(255,255,255,${Math.max(0.08, 0.55 - (f.depth - 1) * 0.09)})`;
      ctx.lineWidth = f.depth === 1 ? 1 : 0.5;
      ctx.strokeRect(f.r.x + 0.25, f.r.y + 0.25, f.r.w - 0.5, f.r.h - 0.5);
    }
    ctx.restore();
  }

  function paint() {
    const w = stage.clientWidth, h = stage.clientHeight;
    if (w < 2 || h < 2) return;
    const scale = Math.min(2, window.devicePixelRatio || 1);
    size = { w, h, scale };
    for (const c of [canvas, overlay]) {
      c.width = Math.round(w * scale);
      c.height = Math.round(h * scale);
    }
    ({ cells, frames } = layout(root, w, h, colorOf));
    const img = ctx.createImageData(canvas.width, canvas.height);
    render(img, cells, scale, focus);
    ctx.putImageData(img, 0, 0);
    drawGroupBorders();
    drawLabels();
    rootEl.classList.add('is-live');
    drawOverlay();
  }

  // The selection is a 2 pt white outline and the tile under the pointer a 1 pt one, as in TreemapView.draw.
  function outline(r: Rect, selection: boolean) {
    octx.save();
    octx.scale(size.scale, size.scale);
    const inset = selection ? 1 : 0.5;
    octx.strokeStyle = selection ? '#fff' : 'rgba(255,255,255,0.85)';
    octx.lineWidth = selection ? 2 : 1;
    octx.strokeRect(r.x + inset, r.y + inset, Math.max(0, r.w - 2 * inset), Math.max(0, r.h - 2 * inset));
    octx.restore();
  }

  function rectOf(n: DemoNode): Rect | null {
    const c = cells.find((x) => x.node === n);
    if (c) return c.r;
    const f = frames.find((x) => x.node === n && x.depth > 0);
    return f ? f.r : null;
  }

  function drawOverlay() {
    octx.clearRect(0, 0, overlay.width, overlay.height);
    if (hovered && hovered.node !== selected) outline(hovered.r, false);
    if (selected) {
      const r = rectOf(selected);
      if (r) outline(r, true);
    }
  }

  function describe(n: DemoNode) {
    const kind = n.children ? 'folder' : extLabel(n.ext ?? '') + ' file';
    return `${pathOf(n)} · ${formatBytes(n.size)} · ${kind}`;
  }

  function updateStatus() {
    if (selected) {
      // Name and size first: a narrow window cuts off the folder it is in, not what it is.
      const pct = ((selected.size / root.size) * 100).toFixed(1);
      statusText.textContent = `${selected.name} · ${formatBytes(selected.size)} · ${pct} % of ${root === disk ? 'the disk' : root.name} · in ${where(selected.parent!)}`;
    } else {
      statusText.textContent = `${where(root)} · ${formatBytes(root.size)} · click a tile to select it`;
    }
    zoomIn.disabled = !selected || selected === root || !(selected.children || selected.parent !== root);
    zoomOut.disabled = root === disk;
  }

  function renderCrumbs() {
    const chain: DemoNode[] = [];
    for (let a: DemoNode | undefined = root; a; a = a.parent) chain.unshift(a);
    crumbs.innerHTML = '';
    chain.forEach((n, i) => {
      if (i > 0) {
        const sep = document.createElement('span');
        sep.className = 'tm-sep';
        sep.setAttribute('aria-hidden', 'true');
        sep.textContent = '›';
        crumbs.appendChild(sep);
      }
      const last = i === chain.length - 1;
      const b = document.createElement(last ? 'span' : 'button');
      b.className = 'tm-crumb';
      b.textContent = n.name;
      if (last) b.setAttribute('aria-current', 'location');
      else {
        (b as HTMLButtonElement).type = 'button';
        b.addEventListener('click', () => zoomTo(n));
      }
      crumbs.appendChild(b);
    });
    crumbs.scrollLeft = crumbs.scrollWidth;
  }

  function zoomTo(n: DemoNode) {
    if (!n.children || n === root) return;
    // The crumbs are rebuilt and the zoom-out button can go disabled, either of which would drop keyboard focus to
    // the page, so it moves to the map instead.
    const hadFocus = rootEl.contains(document.activeElement);
    root = n;
    if (selected && (selected === root || !isInside(selected, root))) selected = null;
    hovered = null;
    tip.hidden = true;
    renderCrumbs();
    paint();
    updateStatus();
    const active = document.activeElement as HTMLElement | null;
    if (hadFocus && (!active || !rootEl.contains(active) || (active as HTMLButtonElement).disabled)) overlay.focus({ preventScroll: true });
    live.textContent = `Zoomed to ${where(n)}, ${formatBytes(n.size)}`;
  }

  function renderTypes() {
    typeList.innerHTML = '';
    typeHead.textContent = `top 12 of ${types.length}`;
    for (const t of types.slice(0, 12)) {
      const b = document.createElement('button');
      b.type = 'button';
      b.className = 'tm-type';
      b.setAttribute('aria-pressed', String(focus === t.color));
      b.innerHTML = `<span class="tm-swatch" style="background:${css(rgbOf(t.color))}"></span><span class="tm-ext"></span><span class="tm-tsize"></span><span class="tm-pct"></span>`;
      b.querySelector('.tm-ext')!.textContent = extLabel(t.ext);
      b.querySelector('.tm-tsize')!.textContent = formatBytes(t.size);
      b.querySelector('.tm-pct')!.textContent = `${((t.size / disk.size) * 100).toFixed(1)} %`;
      b.title = `${t.count.toLocaleString('en-US')} ${t.count === 1 ? 'file' : 'files'}`;
      b.addEventListener('click', () => setFocus(focus === t.color ? null : t.color));
      typeList.appendChild(b);
    }
  }

  function setFocus(c: number | null) {
    focus = c;
    typeList.querySelectorAll<HTMLButtonElement>('.tm-type').forEach((b, i) => b.setAttribute('aria-pressed', String(types[i].color === c)));
    const t = c === null ? null : types.find((x) => x.color === c)!;
    focusLabel.hidden = !t;
    if (t) {
      focusLabel.querySelector('.tm-focus-name')!.textContent = extLabel(t.ext);
      (focusLabel.querySelector('.tm-swatch') as HTMLElement).style.background = css(rgbOf(t.color));
    }
    paint();
    live.textContent = t ? `${extLabel(t.ext)} files lit, ${formatBytes(t.size)} in all; every other type set back` : 'All file types lit';
  }

  // ----- pointer -----
  const local = (e: MouseEvent) => {
    const b = overlay.getBoundingClientRect();
    return { x: e.clientX - b.left, y: e.clientY - b.top };
  };
  overlay.addEventListener('pointermove', (e) => {
    if (e.pointerType === 'touch') return;
    const p = local(e);
    const c = cellAt(p.x, p.y);
    if (c !== hovered) { hovered = c; drawOverlay(); }
    if (!c) { tip.hidden = true; return; }
    tip.querySelector('.tm-tip-path')!.textContent = pathOf(c.node);
    tip.querySelector('.tm-tip-detail')!.textContent = `${formatBytes(c.node.size)} · ${c.node.children ? 'folder' : extLabel(c.node.ext ?? '')}`;
    tip.hidden = false;
    const sw = stage.clientWidth, sh = stage.clientHeight, tw = tip.offsetWidth, th = tip.offsetHeight;
    let x = p.x + 14, y = p.y + 16;
    if (x + tw > sw - 6) x = Math.max(6, p.x - tw - 12);
    if (y + th > sh - 6) y = Math.max(6, p.y - th - 12);
    tip.style.transform = `translate(${x}px, ${y}px)`;
  });
  overlay.addEventListener('pointerleave', () => { hovered = null; tip.hidden = true; drawOverlay(); });
  function select(n: DemoNode | null) {
    selected = n;
    drawOverlay();
    updateStatus();
    if (n) live.textContent = `Selected ${describe(n)}`;
  }
  overlay.addEventListener('click', (e) => {
    const p = local(e);
    select(cellAt(p.x, p.y)?.node ?? null);
  });
  overlay.addEventListener('dblclick', (e) => {
    const p = local(e);
    // As in the app: a folder drawn as one tile zooms to itself; a file zooms to the innermost folder holding it.
    const c = cellAt(p.x, p.y);
    if (c && c.node.children) return zoomTo(c.node);
    const f = frameAt(p.x, p.y);
    if (f && f.depth > 0) zoomTo(f.node);
  });

  const zoomToSelection = () => {
    if (!selected || selected === root) return;
    zoomTo(selected.children ? selected : selected.parent!);
  };
  zoomIn.addEventListener('click', zoomToSelection);
  zoomOut.addEventListener('click', () => { if (root.parent) zoomTo(root.parent); });
  focusLabel.addEventListener('click', () => setFocus(null));

  // Keys, while something in the demo has focus. ⌘[ and ⌘0 zoom out and reset as they do in the app; ⌘[ is always
  // kept from the browser here, where it would otherwise go Back. Esc takes a file type out of focus.
  rootEl.addEventListener('keydown', (e) => {
    const cmd = e.metaKey || e.ctrlKey;
    if (cmd && e.key === '[') {
      e.preventDefault();
      if (root.parent) zoomTo(root.parent);
    } else if (cmd && e.key === '0' && root !== disk) {
      // Only when zoomed in: at the top, ⌘0 is left to the browser's own reset of the page zoom.
      e.preventDefault();
      zoomTo(disk);
    } else if (e.key === 'Escape' && focus !== null) {
      setFocus(null);
    }
  });
  // With the map focused, the arrow keys step through what is in the folder on show, biggest first, Return zooms
  // into the selected folder and Backspace zooms out, so the demo can be used without a pointer.
  overlay.addEventListener('keydown', (e) => {
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    // Only what the map has a tile for: a sliver too thin to draw would take the selection out of sight.
    const kids = (root.children ?? []).filter((k) => rectOf(k)).sort((a, b) => b.size - a.size);
    if (['ArrowRight', 'ArrowDown', 'ArrowLeft', 'ArrowUp', 'Home', 'End'].includes(e.key)) {
      e.preventDefault();
      if (!kids.length) return;
      let top: DemoNode | null = selected;
      while (top && top.parent !== root) top = top.parent ?? null;
      const at = top ? kids.indexOf(top) : -1;
      const forward = e.key === 'ArrowRight' || e.key === 'ArrowDown';
      const next = e.key === 'Home' ? 0 : e.key === 'End' ? kids.length - 1
        : at < 0 ? (forward ? 0 : kids.length - 1)
        : top !== selected ? at
        : Math.max(0, Math.min(kids.length - 1, at + (forward ? 1 : -1)));
      select(kids[next]);
    } else if (e.key === 'Enter') {
      e.preventDefault();
      zoomToSelection();
    } else if (e.key === 'Backspace') {
      e.preventDefault();
      if (root.parent) zoomTo(root.parent);
    }
  });

  let pending = 0;
  new ResizeObserver(() => {
    cancelAnimationFrame(pending);
    pending = requestAnimationFrame(paint);
  }).observe(stage);

  // The first paint comes from the observer, once the stage has its size.
  renderCrumbs();
  renderTypes();
  updateStatus();
}
