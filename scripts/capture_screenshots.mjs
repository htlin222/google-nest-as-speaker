import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const require = createRequire(import.meta.url);
let playwright;
try { playwright = require('playwright'); }
catch {
  const globalRoot = execFileSync('npm', ['root', '-g'], { encoding: 'utf8' }).trim();
  playwright = require(path.join(globalRoot, 'playwright'));
}
const base = process.env.NEST_PREVIEW_URL || 'http://127.0.0.1:8992';
const target = path.join(root, 'assets/screenshots');
await mkdir(target, { recursive: true });
const browser = await playwright.chromium.launch({ channel: process.env.PLAYWRIGHT_CHANNEL || 'chrome', headless: true });
try {
  const phone = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true, colorScheme: 'dark' });
  const remote = await phone.newPage();
  await remote.goto(`${base}/remote?token=documentation-demo-only`);
  await remote.waitForFunction(() => document.querySelector('#title').textContent === 'Midnight Coast — Live Session');
  await remote.evaluate(() => document.fonts.ready);
  if (await remote.evaluate(() => document.body.scrollWidth > innerWidth)) throw new Error('Phone layout overflows');
  await remote.screenshot({ path: path.join(target, 'iphone-remote.png'), fullPage: true, animations: 'disabled' });

  const pairing = await phone.newPage();
  await pairing.goto(`${base}/pairing`);
  await pairing.locator('#pair').waitFor({ state: 'visible' });
  await pairing.screenshot({ path: path.join(target, 'phone-pairing.png'), animations: 'disabled' });
  await phone.close();

  const desktop = await browser.newContext({ viewport: { width: 1600, height: 1000 }, deviceScaleFactor: 2 });
  const hero = await desktop.newPage();
  await hero.goto(`${base}/showcase`);
  await hero.evaluate(async () => { await document.fonts.ready; await Promise.all([...document.images].map(image => image.decode())); });
  await hero.screenshot({ path: path.join(target, 'feature-overview.png'), animations: 'disabled' });
  await desktop.close();
  await writeFile(path.join(target, 'capture.json'), JSON.stringify({
    fixture: 'Fictional documentation data; no real devices, files, cookies or credentials',
    native: 'Production playback panel rendered in memory by AppKit in DEBUG with PlayerModel(preview: true); sidebar excluded',
    browser: 'Playwright Chromium with installed Chrome; fresh temporary contexts',
    phoneViewport: { width: 390, height: 844, scale: 2 },
    heroViewport: { width: 1600, height: 1000, scale: 2 },
    artifacts: ['native-player.png', 'iphone-remote.png', 'phone-pairing.png', 'feature-overview.png'],
  }, null, 2) + '\n');
  console.log('Created real-UI documentation screenshots in assets/screenshots/');
} finally { await browser.close(); }
