# Wizzzee website

The site at https://saibarathr.github.io/wizzzee/, built with [Astro](https://astro.build) into plain static files.
The only JavaScript on the pages is a few small scripts (theme, copy buttons, download links, the screenshot tabs)
and the treemap demo on the home page.

```sh
cd site
npm ci
npm run dev       # http://localhost:4321/wizzzee/
npm run build     # static site in site/dist
npm run preview   # serve site/dist
```

`.github/workflows/pages.yml` builds and deploys it on every push to `main` that touches `site/`, `docs/` or
`Resources/Info.plist`.

## Where the content comes from

| Page | Source |
| --- | --- |
| Home, Download | `src/pages/index.astro`, `src/pages/download.astro` |
| Getting started, Using Wizzzee, Search and filters, Reading the numbers | `src/guides/*.md` |
| Command line | `docs/cli.md`, rendered as is |
| How it works | `docs/architecture.md`, rendered as is |
| Changelog | `docs/releases/*.md`, newest version first |

The version in example file names is read from `Resources/Info.plist`. Download buttons point at the latest GitHub
release, and a small script swaps in the zip's direct link and size when GitHub's API answers.

## The treemap demo

The treemap on the home page is a port of the app's own layout and renderer (`src/lib/treemap-demo.ts`, from
`Sources/Wizzzee/Treemap/TreemapLayout.swift` and `TreemapRenderer.swift`): the same squarified layout, cushion
constants, palette and set-back for a file type in focus. It draws a made-up disk generated from a fixed seed in
`src/lib/demo-disk.ts`. If the app's shading changes, change the constants there too. Without JavaScript, the static
`public/images/treemap.webp` shows in its place.

## Images and media

- `public/images/*.webp` are `docs/images/*.png`, resized to 2000 px wide (the guide to 1400) with
  `cwebp -q 80 -m 6 -resize 2000 0`.
- `public/media/promo.mp4` is `promo/out/wizzzee-promo.mp4` at 1280×720
  (`ffmpeg -vf scale=1280:-2 -c:v libx264 -preset slow -crf 26 -c:a aac -b:a 128k -movflags +faststart`), and
  `promo-poster.webp` a frame from 7 seconds in. Music: "Rocket Power" by Kevin MacLeod (incompetech.com), CC BY 4.0.
- `public/favicon.svg`, the mark in the header, is drawn by `node scripts/make-mark.mjs`: the app icon from
  `scripts/make-icon.swift`, flat. The PNG and ICO favicons are rendered from it.
- `public/og.png` (1200×630) is the social preview.

## Design

Cool neutral greys from the icon's dark plate, and one solid orange accent, the treemap palette's first colour. The
wordmark's three z's take the palette's orange, magenta and blue, as in the promo video. The demo window and
screenshots are the app's own dark appearance in both of the site's themes. No gradients.

Icons are from [Lucide](https://lucide.dev) (ISC license), drawn inline at build time.
