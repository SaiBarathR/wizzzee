import fs from 'node:fs';
import path from 'node:path';

/** The app version in ../Resources/Info.plist at build time, used for example file names. */
export const APP_VERSION: string = (() => {
  try {
    const plist = fs.readFileSync(path.resolve(process.cwd(), '..', 'Resources', 'Info.plist'), 'utf8');
    return plist.match(/<key>CFBundleShortVersionString<\/key>\s*<string>([0-9.]+)<\/string>/)?.[1] ?? '0.6.2';
  } catch {
    return '0.6.2';
  }
})();

export const SITE = {
  name: 'Wizzzee',
  url: 'https://saibarathr.github.io/wizzzee/',
  repo: 'https://github.com/SaiBarathR/wizzzee',
  releases: 'https://github.com/SaiBarathR/wizzzee/releases',
  latestRelease: 'https://github.com/SaiBarathR/wizzzee/releases/latest',
  releasesApi: 'https://api.github.com/repos/SaiBarathR/wizzzee/releases/latest',
  description:
    'Wizzzee is a fast, native disk space analyzer for macOS: a folder tree with sizes, the biggest files, and a treemap you can click into. Free and open source.',
};

/** Prefix a site path with the base path (/wizzzee/). */
export function url(p = ''): string {
  const base = import.meta.env.BASE_URL.replace(/\/?$/, '/');
  return base + p.replace(/^\//, '');
}
