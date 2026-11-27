// A made-up Mac startup disk for the treemap demo on the home page: the folders a developer's Mac tends to have,
// with files sized the way those folders usually are. Generated from a fixed seed, so every visitor sees the same
// disk, and built in the browser, so the page doesn't carry thousands of rows of JSON.

export interface DemoNode {
  name: string;
  /** Bytes. For a folder, the sum of everything inside it. */
  size: number;
  /** Lower-case extension without the dot, '' for none. Files only. */
  ext?: string;
  children?: DemoNode[];
  parent?: DemoNode;
}

const KB = 1e3, MB = 1e6, GB = 1e9;

function rng(seed: number) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export function buildDemoDisk(): DemoNode {
  const rand = rng(0x5a17e);
  const pick = <T,>(xs: T[]) => xs[Math.floor(rand() * xs.length)];
  /** Log-normal around `median`, `spread` octaves wide. */
  const around = (median: number, spread = 1.2) => {
    const u = Math.max(1e-9, rand()), v = rand();
    const z = Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v);
    return Math.max(1, Math.round(median * Math.pow(2, z * spread)));
  };
  const hex = (n: number) => Array.from({ length: n }, () => '0123456789abcdef'[Math.floor(rand() * 16)]).join('');
  const uuid = () => `${hex(8)}-${hex(4)}-${hex(4)}-${hex(4)}-${hex(12)}`.toUpperCase();

  type Spec = [ext: string, count: number, median: number, spread?: number, names?: string[] | ((i: number) => string)];
  const words = ['index', 'main', 'core', 'utils', 'render', 'cache', 'store', 'view', 'model', 'client', 'server', 'types', 'parser', 'theme', 'layout', 'router', 'api', 'auth', 'image', 'font'];

  function file(name: string, size: number, ext?: string): DemoNode {
    const e = ext ?? (name.includes('.') ? name.split('.').pop()!.toLowerCase() : '');
    return { name, size, ext: e };
  }
  function files(specs: Spec[]): DemoNode[] {
    const out: DemoNode[] = [];
    for (const [ext, count, median, spread, names] of specs) {
      for (let i = 0; i < count; i++) {
        const base = typeof names === 'function' ? names(i) : names ? names[i % names.length] + (i >= names.length ? `-${i}` : '') : `${pick(words)}${i ? '-' + i : ''}`;
        out.push(file(ext && !base.toLowerCase().endsWith('.' + ext) ? `${base}.${ext}` : base, around(median, spread ?? 1.2), ext));
      }
    }
    return out;
  }
  const dir = (name: string, ...kids: (DemoNode | DemoNode[])[]): DemoNode => ({ name, size: 0, children: kids.flat() });

  // ---------- ~/Library ----------
  const derivedData = dir('DerivedData',
    ...['Helprr', 'Glint', 'Wizzzee', 'PortWatch', 'Mirage', 'Streamyfin'].map((p) =>
      dir(`${p}-${hex(28)}`,
        dir('Build',
          dir('Intermediates.noindex', files([['o', 60, 1.6 * MB, 1.4], ['swiftmodule', 14, 4 * MB], ['dia', 30, 40 * KB], ['pcm', 12, 18 * MB]])),
          dir('Products', files([['', 3, 60 * MB, 0.8, [p]], ['dylib', 6, 9 * MB]]))),
        dir('Index.noindex', files([['', 40, 6 * MB, 1.3, (i) => `${hex(16)}${i}`]])))));
  const deviceSupport = dir('iOS DeviceSupport',
    ...['iPhone17,1 18.2 (22C152)', 'iPhone16,2 17.6 (21G80)', 'iPad14,1 18.1 (22B83)'].map((v) =>
      dir(v, dir('Symbols', dir('System', dir('Library', files([['dylib', 120, 22 * MB, 1.3], ['', 40, 30 * MB, 1.2, (i) => `Framework${i}`]])))))));
  const simulators = dir('Devices',
    ...Array.from({ length: 7 }, () =>
      dir(uuid(), dir('data',
        dir('Containers', files([['sqlite', 8, 30 * MB], ['png', 60, 900 * KB], ['car', 10, 14 * MB], ['', 30, 8 * MB, 1.4, (i) => `blob${i}`]])),
        dir('Library', files([['db', 12, 40 * MB], ['plist', 30, 40 * KB], ['', 1, 900 * MB, 0.4, ['dyld_sim_shared_cache_arm64e']]]))))));
  const developer = dir('Developer',
    dir('Xcode', derivedData, deviceSupport,
      dir('Archives', ...['2026-09-14', '2026-10-02', '2026-11-11'].map((d) => dir(d, dir('Wizzzee.xcarchive', files([['', 1, 120 * MB, 0.5, ['Wizzzee']], ['dylib', 8, 40 * MB, 0.8], ['dwarf', 4, 90 * MB, 0.8]])))))),
    dir('CoreSimulator', simulators, dir('Caches', files([['dylib', 30, 50 * MB, 1.2]]))));

  const containers = dir('Containers',
    dir('com.docker.docker', dir('Data', dir('vms', dir('0', dir('data', file('Docker.raw', 23.6 * GB))))), files([['log', 20, 18 * MB]])),
    dir('com.apple.mail', files([['emlx', 300, 120 * KB, 1.8]])),
    dir('com.apple.Safari', files([['db', 10, 60 * MB], ['png', 80, 300 * KB]])),
    dir('com.apple.news', files([['', 60, 9 * MB, 1.3, (i) => `article${i}`]])));
  const caches = dir('Caches',
    dir('com.spotify.client', dir('Data', files([['file', 160, 12 * MB, 1.1]]))),
    dir('Homebrew', dir('downloads', files([['gz', 40, 40 * MB, 1.5, (i) => `${hex(12)}--bottle${i}.tar`]]))),
    dir('Google', dir('Chrome', files([['', 200, 2 * MB, 1.8, (i) => `f_${hex(6)}${i}`]]))),
    dir('pip', files([['whl', 30, 30 * MB, 1.4]])),
    dir('Yarn', files([['tgz', 400, 400 * KB, 2]])),
    dir('com.apple.Safari', files([['db', 6, 120 * MB]])));
  const appSupport = dir('Application Support',
    dir('MobileSync', dir('Backup', dir(uuid(), files([['', 380, 14 * MB, 1.9, (i) => hex(40) + i]])))),
    dir('Slack', files([['ldb', 60, 9 * MB], ['log', 20, 6 * MB]])),
    dir('Code', dir('User', dir('workspaceStorage', files([['vscdb', 40, 18 * MB, 1.4]])))),
    dir('Google', dir('Chrome', dir('Default', files([['ldb', 80, 4 * MB], ['', 40, 9 * MB, 1.3, (i) => `History${i}`]])))),
    dir('Steam', dir('steamapps', dir('common', dir('Hollow Grove', files([['pak', 6, 1.4 * GB, 0.7], ['dylib', 20, 30 * MB]]))))));
  const library = dir('Library', developer, containers, caches, appSupport,
    dir('Mail', dir('V10', files([['emlx', 500, 90 * KB, 1.9]]))),
    dir('Messages', dir('Attachments', files([['heic', 200, 2.4 * MB], ['mov', 30, 40 * MB, 1.3], ['jpg', 120, 900 * KB]]))));

  // ---------- the rest of the home folder ----------
  const movies = dir('Movies',
    files([['mov', 22, 1.3 * GB, 1.1, (i) => `Screen Recording 2026-${String(1 + (i % 12)).padStart(2, '0')}-${String(3 + i).padStart(2, '0')}`]]),
    dir('Exports', files([['mp4', 14, 700 * MB, 1.0]])),
    dir('Wizzzee Promo.fcpbundle', dir('Render Files', files([['mov', 30, 260 * MB, 1.0]]))));
  const pictures = dir('Pictures',
    dir('Photos Library.photoslibrary',
      dir('originals', ...'0123456789ABCDEF'.split('').map((c) => dir(c, files([['heic', 70, 2.6 * MB, 0.8, () => uuid()], ['jpg', 20, 4 * MB, 0.9, () => uuid()], ['mov', 4, 60 * MB, 1.2, () => uuid()]])))),
      dir('resources', dir('derivatives', files([['jpeg', 600, 260 * KB, 1.0]]))),
      dir('database', files([['sqlite', 3, 400 * MB, 0.5]]))),
    files([['png', 30, 3 * MB], ['psd', 6, 160 * MB]]));
  const downloads = dir('Downloads',
    file('Xcode_16.4.xip', 3.1 * GB),
    files([['dmg', 14, 380 * MB, 1.4, ['Docker', 'Figma', 'Blender-4.5', 'Ableton Live 12', 'Android Studio', 'UTM', 'OBS', 'VLC', 'Zed', 'Ollama', 'Raycast', 'Firefox', 'Arc', 'Steam']],
      ['zip', 26, 120 * MB, 1.8], ['pkg', 6, 400 * MB, 1.1], ['pdf', 60, 3 * MB, 1.6], ['iso', 1, 6.2 * GB, 0.1, ['ubuntu-24.04-desktop-arm64']]]));
  const projects = dir('Projects',
    ...['helprr', 'glint', 'wizzzee', 'port-watch', 'insta-timeline', 'manga-downloader', 'hospital-crm', 'redis-console'].map((p, i) =>
      dir(p,
        i % 3 === 2 ? [] : dir('node_modules', ...['typescript', 'react-dom', '@babel', 'esbuild', 'next', 'webpack', '@swc', 'lodash', 'rxjs', 'prettier'].map((m) =>
          dir(m, files([['js', 30, 60 * KB, 2.2], ['map', 12, 120 * KB, 1.8], ['json', 6, 8 * KB], ['node', m === 'esbuild' || m === '@swc' ? 2 : 0, 22 * MB, 0.4]])))),
        dir('.git', dir('objects', dir('pack', files([['pack', 2, 160 * MB, 1.4]])))),
        dir('src', files([[i % 2 ? 'swift' : 'ts', 50, 9 * KB, 1.2]])),
        i % 2 ? dir('.build', files([['o', 40, 2 * MB, 1.3]])) : [])));
  const music = dir('Music', dir('Music', dir('Media.localized', files([['m4a', 500, 9 * MB, 0.6], ['mp3', 200, 7 * MB, 0.6]]))));
  const documents = dir('Documents', files([['pdf', 120, 2 * MB, 1.8], ['key', 12, 120 * MB, 1.2], ['docx', 40, 500 * KB, 1.4], ['psd', 8, 300 * MB, 0.9], ['xlsx', 30, 400 * KB, 1.2]]));
  const home = dir('you', library, movies, pictures, downloads, projects, music, documents,
    dir('.Trash', files([['dmg', 3, 500 * MB], ['zip', 10, 50 * MB, 1.5]])),
    dir('.ollama', dir('models', dir('blobs', files([['', 5, 4.2 * GB, 0.6, (i) => `sha256-${hex(64)}${i}`]])))));

  // ---------- outside the home folder ----------
  const app = (name: string, scale: number, extra: Spec[] = []) =>
    dir(`${name}.app`, dir('Contents',
      dir('MacOS', files([['', 1, 80 * MB * scale, 0.5, [name]]])),
      dir('Frameworks', files([['dylib', 30, 14 * MB * scale, 1.3], ...extra])),
      dir('Resources', files([['car', 2, 30 * MB * scale], ['nib', 30, 60 * KB], ['icns', 2, 1.2 * MB], ['pak', 10, 6 * MB * scale]]))));
  const xcode = dir('Xcode.app', dir('Contents',
    dir('Developer', dir('Platforms', ...['iPhoneOS', 'MacOSX', 'AppleTVOS', 'WatchOS', 'XROS'].map((p) =>
      dir(`${p}.platform`, files([['tbd', 200, 400 * KB, 1.4], ['swiftmodule', 60, 6 * MB, 1.1], ['dylib', 40, 20 * MB, 1.2], ['a', 10, 30 * MB]])))),
      dir('Toolchains', dir('XcodeDefault.xctoolchain', files([['dylib', 30, 40 * MB, 1.2], ['', 40, 30 * MB, 1.2, (i) => `swift-tool-${i}`]])))),
    dir('Frameworks', files([['dylib', 30, 20 * MB]])), dir('SharedFrameworks', files([['dylib', 50, 18 * MB]]))));
  const applications = dir('Applications', xcode,
    app('Docker', 4, [['', 6, 120 * MB, 0.8, (i) => `com.docker.backend${i}`]]),
    app('Google Chrome', 3), app('Slack', 2, [['asar', 1, 180 * MB]]), app('Visual Studio Code', 2, [['asar', 2, 90 * MB]]),
    app('Figma', 2), app('Spotify', 1.5), app('Final Cut Pro', 6, [['caf', 120, 9 * MB, 1.0]]),
    app('Logic Pro', 3, [['caf', 400, 12 * MB, 1.0]]), app('Blender', 4), app('Ableton Live 12 Suite', 3, [['wav', 300, 9 * MB, 1.2]]));
  const system = dir('System', dir('Library',
    dir('AssetsV2', ...['com_apple_MobileAsset_iOSSimulatorRuntime', 'com_apple_MobileAsset_UAF_Siri_Understanding', 'com_apple_MobileAsset_LinguisticData', 'com_apple_MobileAsset_Font7', 'com_apple_MobileAsset_MacSoftwareUpdate'].map((a, i) =>
      dir(a, dir(`${hex(40)}.asset`, dir('AssetData', files([[i === 0 ? 'dmg' : '', i === 0 ? 1 : 30, i === 0 ? 8.1 * GB : 40 * MB, 1.3, (k) => `asset${k}`]])))))),
    dir('PrivateFrameworks', files([['', 300, 9 * MB, 1.6, (i) => `Private${i}`], ['dylib', 100, 3 * MB, 1.4]])),
    dir('Frameworks', files([['', 120, 8 * MB, 1.5, (i) => `Framework${i}`]])),
    dir('Fonts', files([['ttc', 40, 9 * MB, 1.2], ['ttf', 200, 400 * KB, 1.3]])),
    dir('Desktop Pictures', files([['heic', 30, 14 * MB, 0.8], ['mov', 6, 90 * MB, 0.8]])),
    dir('Templates', dir('Data', files([['sql', 80, 9 * MB, 1.4], ['db', 30, 12 * MB, 1.2]])))));
  const libraryRoot = dir('Library',
    dir('Developer', dir('CommandLineTools', files([['tbd', 400, 200 * KB, 1.4], ['dylib', 80, 10 * MB, 1.3], ['h', 600, 20 * KB, 1.6]]))),
    dir('Application Support', dir('Apple', files([['', 40, 30 * MB, 1.5, (i) => `support${i}`]]))),
    dir('Caches', files([['', 80, 10 * MB, 1.8, (i) => `cache${i}`]])),
    dir('Audio', dir('Apple Loops', files([['caf', 600, 3 * MB, 1.0]]))));
  const priv = dir('private', dir('var',
    dir('vm', files([['', 4, 1.07 * GB, 0.05, ['swapfile0', 'swapfile1', 'swapfile2', 'swapfile3']]]), file('sleepimage', 2.1 * GB, '')),
    dir('folders', files([['', 300, 2 * MB, 2.0, (i) => `tmp.${hex(8)}${i}`]])),
    dir('db', files([['db', 30, 30 * MB, 1.5], ['', 30, 20 * MB, 1.5, (i) => `uuidtext${i}`]]))));
  const opt = dir('opt', dir('homebrew', dir('Cellar', ...['llvm', 'python@3.13', 'ffmpeg', 'node', 'go', 'rust', 'imagemagick', 'qt'].map((f) =>
    dir(f, files([['dylib', 30, 9 * MB, 1.3], ['', 20, 6 * MB, 1.2, (i) => `${f}-bin${i}`], ['a', 6, 20 * MB], ['h', 200, 15 * KB, 1.4]]))))));
  const usr = dir('usr', dir('lib', files([['dylib', 200, 2 * MB, 1.6]])), dir('share', files([['gz', 400, 30 * KB, 1.5]])), dir('bin', files([['', 300, 300 * KB, 1.8, (i) => `tool${i}`]])));

  const root = dir('Macintosh HD', dir('Users', home, dir('Shared', files([['', 20, 3 * MB, 1.5, (i) => `shared${i}`]]))), applications, system, libraryRoot, priv, opt, usr);

  (function total(n: DemoNode): number {
    if (!n.children) return n.size;
    n.children = n.children.filter((c) => (c.children ? c.children.length > 0 : c.size > 0));
    n.size = 0;
    for (const c of n.children) {
      c.parent = n;
      n.size += total(c);
    }
    return n.size;
  })(root);
  return root;
}

/** Bytes in base-10 units, as the app and Finder show them. */
export function formatBytes(n: number): string {
  const units = ['bytes', 'KB', 'MB', 'GB', 'TB'];
  let u = 0;
  let v = n;
  while (v >= 1000 && u < units.length - 1) { v /= 1000; u++; }
  if (u === 0) return `${Math.round(v)} bytes`;
  return `${v < 100 ? v.toFixed(1) : Math.round(v)} ${units[u]}`;
}

/** The path from the disk down to `n`, the disk shown as "/". */
export function pathOf(n: DemoNode): string {
  const parts: string[] = [];
  for (let at: DemoNode | undefined = n; at && at.parent; at = at.parent) parts.unshift(at.name);
  return '/' + parts.join('/');
}
