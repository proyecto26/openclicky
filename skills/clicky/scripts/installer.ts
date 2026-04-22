import { spawn, spawnSync } from 'node:child_process';
import { createWriteStream, existsSync, unlinkSync, readFileSync, readdirSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { pipeline } from 'node:stream/promises';
import { createHash } from 'node:crypto';
import { assertDarwin, resolveDownloadsDir, ensureDir } from './paths.ts';
import type { InstallResult } from './types.ts';

export const CLICKY_TAP = 'proyecto26/tap/clicky-ai';
export const CLICKY_RELEASE_REPO = 'proyecto26/clicky-ai-plugin';
export const INSTALLED_PATH = '/Applications/Clicky.app';

export interface InstallOptions {
  force?: boolean;
  dryRun?: boolean;
}

export async function install(options: InstallOptions = {}): Promise<InstallResult> {
  assertDarwin();

  if (!options.force && existsSync(INSTALLED_PATH)) {
    return { ok: true, path: INSTALLED_PATH, method: 'already-installed' };
  }

  if (options.dryRun) {
    const decisions: string[] = [];
    decisions.push(options.force ? 'force=true → skipping already-installed check' : 'already-installed → would short-circuit');
    decisions.push(isBrewAvailable() ? `brew available → would run: brew install ${CLICKY_TAP}` : 'brew not available → skipping to DMG');
    decisions.push(`DMG fallback: github.com/${CLICKY_RELEASE_REPO} latest → download → verify SHA256 → hdiutil attach → cp to /Applications`);
    decisions.push('Last resort: print manual URL');
    return { ok: true, method: 'manual', reason: `dry-run decisions:\n  ${decisions.join('\n  ')}` };
  }

  if (isBrewAvailable()) {
    const brewResult = await tryBrewInstall();
    if (brewResult.ok) return brewResult;
    process.stderr.write(`[clicky:install] brew path failed, falling back to DMG: ${brewResult.reason}\n`);
  } else {
    process.stderr.write('[clicky:install] brew not found, using DMG fallback\n');
  }

  const dmgResult = await tryDmgInstall();
  if (dmgResult.ok) return dmgResult;

  return {
    ok: false,
    method: 'manual',
    reason:
      `Automatic install failed. Download manually from https://github.com/${CLICKY_RELEASE_REPO}/releases ` +
      `and copy Clicky.app to /Applications/. Underlying reason: ${dmgResult.reason}`,
  };
}

function isBrewAvailable(): boolean {
  const r = spawnSync('brew', ['--version'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
  return r.status === 0;
}

function tryBrewInstall(): Promise<InstallResult> {
  return new Promise((resolve) => {
    const child = spawn('brew', ['install', CLICKY_TAP], { stdio: ['ignore', 'pipe', 'pipe'] });
    let stderr = '';
    child.stdout.on('data', (c) => process.stderr.write(String(c)));
    child.stderr.on('data', (c) => {
      stderr += String(c);
      process.stderr.write(String(c));
    });
    child.on('close', (code) => {
      if (code === 0 && existsSync(INSTALLED_PATH)) {
        resolve({ ok: true, path: INSTALLED_PATH, method: 'brew-tap' });
      } else {
        resolve({ ok: false, method: 'brew-tap', reason: `brew install exited ${code}. ${stderr.slice(-400).trim()}` });
      }
    });
    child.on('error', (err) => resolve({ ok: false, method: 'brew-tap', reason: err.message }));
  });
}

async function tryDmgInstall(): Promise<InstallResult> {
  try {
    const release = await fetchLatestRelease();
    const dmgAsset = release.assets.find(
      (a) => /Clicky-.*-arm64\.dmg$/.test(a.name) && !a.name.endsWith('.sha256'),
    );
    const shaAsset = release.assets.find((a) => a.name === `${dmgAsset?.name}.sha256`);
    if (!dmgAsset) {
      return { ok: false, method: 'dmg-download', reason: `no arm64 DMG asset found in release ${release.tag_name}` };
    }

    const dir = ensureDir(resolveDownloadsDir());
    const dmgPath = join(dir, dmgAsset.name);

    await downloadToFile(dmgAsset.browser_download_url, dmgPath);

    if (shaAsset) {
      const expected = await downloadToString(shaAsset.browser_download_url);
      const actual = sha256OfFile(dmgPath);
      const expectedHash = expected.split(/\s+/)[0]?.trim();
      if (!expectedHash || expectedHash.toLowerCase() !== actual.toLowerCase()) {
        unlinkSafe(dmgPath);
        return {
          ok: false,
          method: 'dmg-download',
          reason: `SHA256 mismatch. expected=${expectedHash} actual=${actual}`,
        };
      }
    } else {
      process.stderr.write(`[clicky:install] no .sha256 sidecar for ${dmgAsset.name}; skipping integrity check\n`);
    }

    const mountPoint = await hdiutilAttach(dmgPath);
    try {
      await copyAppFromMount(mountPoint);
      tryRunSync('xattr', ['-rd', 'com.apple.quarantine', INSTALLED_PATH]);
    } finally {
      await hdiutilDetach(mountPoint);
    }

    if (!existsSync(INSTALLED_PATH)) {
      return { ok: false, method: 'dmg-download', reason: 'DMG processed but Clicky.app not present in /Applications/' };
    }
    return { ok: true, path: INSTALLED_PATH, method: 'dmg-download' };
  } catch (err) {
    return { ok: false, method: 'dmg-download', reason: err instanceof Error ? err.message : String(err) };
  }
}

interface GithubRelease {
  tag_name: string;
  assets: Array<{ name: string; browser_download_url: string }>;
}

async function fetchLatestRelease(): Promise<GithubRelease> {
  const url = `https://api.github.com/repos/${CLICKY_RELEASE_REPO}/releases/latest`;
  const res = await fetch(url, { headers: { accept: 'application/vnd.github+json' } });
  if (!res.ok) throw new Error(`GitHub releases HTTP ${res.status} for ${CLICKY_RELEASE_REPO}`);
  return (await res.json()) as GithubRelease;
}

async function downloadToFile(url: string, dest: string): Promise<void> {
  const res = await fetch(url, { redirect: 'follow' });
  if (!res.ok || !res.body) throw new Error(`download HTTP ${res.status}`);
  const out = createWriteStream(dest);
  await pipeline(res.body as unknown as NodeJS.ReadableStream, out);
}

async function downloadToString(url: string): Promise<string> {
  const res = await fetch(url, { redirect: 'follow' });
  if (!res.ok) throw new Error(`download HTTP ${res.status}`);
  return await res.text();
}

function sha256OfFile(path: string): string {
  const buf = readFileSync(path);
  return createHash('sha256').update(buf).digest('hex');
}

function hdiutilAttach(dmgPath: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = spawn('hdiutil', ['attach', '-nobrowse', '-readonly', '-noautoopen', dmgPath], {
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (c) => (stdout += String(c)));
    child.stderr.on('data', (c) => (stderr += String(c)));
    child.on('close', (code) => {
      if (code !== 0) return reject(new Error(`hdiutil attach exited ${code}: ${stderr}`));
      const match = stdout.split('\n').map((l) => l.match(/\s(\/Volumes\/[^\s]+)\s*$/)).find(Boolean);
      const mount = match?.[1];
      if (!mount) return reject(new Error(`hdiutil attach: no mount point in output:\n${stdout}`));
      resolve(mount);
    });
    child.on('error', reject);
  });
}

function hdiutilDetach(mountPoint: string): Promise<void> {
  return new Promise((resolve) => {
    const child = spawn('hdiutil', ['detach', '-quiet', mountPoint], { stdio: 'ignore' });
    child.on('close', () => resolve());
    child.on('error', () => resolve());
  });
}

async function copyAppFromMount(mount: string): Promise<void> {
  const entries = readdirSync(mount);
  const appName = entries.find((e) => e.endsWith('.app'));
  if (!appName) throw new Error(`no .app bundle found in ${mount}`);
  const src = join(mount, appName);

  if (existsSync(INSTALLED_PATH)) {
    rmSync(INSTALLED_PATH, { recursive: true, force: true });
  }
  runSync('cp', ['-R', src, '/Applications/']);

  const installedName = join('/Applications', appName);
  if (installedName !== INSTALLED_PATH && existsSync(installedName)) {
    runSync('mv', [installedName, INSTALLED_PATH]);
  }
}

function runSync(cmd: string, args: string[]): void {
  const r = spawnSync(cmd, args, { encoding: 'utf8' });
  if (r.status !== 0) {
    throw new Error(`${cmd} ${args.join(' ')} exited ${r.status}: ${r.stderr?.trim() ?? ''}`);
  }
}

function tryRunSync(cmd: string, args: string[]): void {
  const r = spawnSync(cmd, args, { encoding: 'utf8' });
  if (r.status !== 0) {
    process.stderr.write(
      `[clicky:install] warn: ${cmd} ${args.join(' ')} exited ${r.status}; continuing. ${r.stderr?.trim() ?? ''}\n`,
    );
  }
}

function unlinkSafe(path: string): void {
  try {
    unlinkSync(path);
  } catch {
    // ignore
  }
}
