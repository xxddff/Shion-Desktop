// Shared plumbing for the Linux tests and measurements: the rfb/ testbed (Xvnc + Hermes' RFB
// filter behind a stand-in bridge), the loopback relay, and the page in headless Chromium.
// Tickets, tokens and header values stay in memory; nothing here prints them.

import { spawn, execFile } from 'node:child_process'
import { createRequire } from 'node:module'
import { readFile, mkdir, rm } from 'node:fs/promises'
import { randomBytes } from 'node:crypto'
import path from 'node:path'

const require = createRequire(import.meta.url)
export const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..')
export const REPO = path.resolve(ROOT, '..')
export const WEB = path.join(ROOT, 'web')
export const TESTBED = path.join(REPO, 'rfb', 'testbed')
export const PY = process.env.RFB_TESTBED_PYTHON || 'python3'
export const PAGE_ORIGIN = 'https://webvnc.test'
// What Cloudflare Access wants (the testbed bridge refuses an upgrade without them, like Access).
export const ACCESS_HEADERS = ['CF-Access-Client-Id: test-client-id', 'CF-Access-Client-Secret: test-client-secret']

export function playwright() {
  try { return require('playwright') } catch { return require('playwright-core') }
}

export const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))

export async function until(probe, { timeout = 10000, every = 25, what = 'condition' } = {}) {
  const deadline = Date.now() + timeout
  for (;;) {
    const value = await probe()
    if (value) return value
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`)
    await sleep(every)
  }
}

function run(file, args, env, { timeout = 10000 } = {}) {
  return new Promise(resolve => {
    execFile(file, args, { env, timeout, maxBuffer: 16 << 20 }, (error, stdout, stderr) => {
      resolve({ code: error ? (error.code ?? 1) : 0, stdout, stderr })
    })
  })
}

// ------------------------------------------------------------------ testbed

export async function startTestbed({ display = ':41', port = 8791, scene = 'live', latencyMs = 0,
  geometry = '1440x900', requireHeaders = ['CF-Access-Client-Id', 'CF-Access-Client-Secret'], name = 'tb' } = {}) {
  // Xvnc's Unix socket lives in here, and socket paths are limited to ~100 bytes
  let runDir = path.join(process.env.WEBVNC_RUN || '/tmp', `wv-${name}`)
  if (path.join(runDir, 'rfb.sock').length > 100) runDir = path.join('/tmp', `wv-${name}-${process.pid}`)
  await rm(runDir, { recursive: true, force: true })
  await mkdir(runDir, { recursive: true })
  const env = {
    ...process.env,
    RFB_TESTBED_DISPLAY: display, RFB_TESTBED_PORT: String(port), RFB_TESTBED_RUN: runDir,
    RFB_TESTBED_SCENE: scene, RFB_TESTBED_LATENCY_MS: String(latencyMs), RFB_TESTBED_GEOMETRY: geometry,
    RFB_TESTBED_REQUIRE_HEADER: requireHeaders.join(' '), NO_PROXY: '127.0.0.1', no_proxy: '127.0.0.1',
  }
  const child = spawn(path.join(TESTBED, 'start.sh'), [], { env, stdio: ['ignore', 'pipe', 'pipe'], detached: true })
  const log = []
  child.stdout.on('data', d => log.push(String(d)))
  child.stderr.on('data', d => log.push(String(d)))
  let exited = false
  child.on('exit', () => { exited = true })
  const api = async (p, init) => {
    const response = await fetch(`http://127.0.0.1:${port}${p}`, init)
    return response.json()
  }
  await until(async () => {
    if (exited) throw new Error(`testbed exited:\n${log.join('')}`)
    try { await api('/lease'); return true } catch { return false }
  }, { timeout: 20000, what: 'the testbed' })
  const xenv = { ...process.env, DISPLAY: display, XAUTHORITY: path.join(runDir, 'Xauthority') }
  const tb = {
    port, display, runDir, env: xenv, log,
    api,
    // like display.observe: a single-use ticket, kept in memory only
    async observe(viewerId) {
      const r = await api(`/observe${viewerId ? `?viewer_id=${encodeURIComponent(viewerId)}` : ''}`)
      return { url: `ws://127.0.0.1:${port}${r.path}?display_ticket=${r.ticket}`, viewerId: r.viewer_id }
    },
    acquire: viewerId => api(`/lease/acquire?viewer_id=${encodeURIComponent(viewerId)}`),
    release: () => api('/lease/release'),
    lease: () => api('/lease'),
    x: (file, args, opts) => run(file, args, xenv, opts),
    async clipboard() {
      const r = await run('xclip', ['-o', '-selection', 'clipboard'], xenv, { timeout: 3000 })
      return r.code === 0 ? r.stdout : null
    },
    async setClipboard(text) {
      await new Promise(resolve => {
        const p = spawn('xclip', ['-i', '-selection', 'clipboard'], { env: xenv, stdio: ['pipe', 'ignore', 'ignore'] })
        p.stdin.end(text)
        p.on('exit', resolve)
      })
    },
    async stop() {
      try { process.kill(-child.pid, 'SIGTERM') } catch { /* gone */ }
      await sleep(300)
      try { process.kill(-child.pid, 'SIGKILL') } catch { /* gone */ }
      await rm(runDir, { recursive: true, force: true }).catch(() => {})
    },
  }
  return tb
}

// A Chrome on the remote desktop, showing `url` (e.g. rfb/testbed/input.html, whose window title
// echoes what is typed into its text box).
export async function remoteChrome(tb, url, { width = 1000, height = 700, name = 'chrome' } = {}) {
  const chrome = process.env.WEBVNC_REMOTE_CHROME || 'google-chrome'
  const dataDir = path.join(tb.runDir, `${name}-profile`)
  const child = spawn(chrome, ['--no-sandbox', '--disable-gpu', '--no-first-run', '--no-default-browser-check',
    '--disable-features=Translate,MediaRouter', '--password-store=basic', `--user-data-dir=${dataDir}`,
    '--window-position=0,0', `--window-size=${width},${height}`, `--app=${url}`],
  { env: tb.env, stdio: 'ignore', detached: true })
  return {
    child,
    async stop() {
      try { process.kill(-child.pid, 'SIGKILL') } catch { /* gone */ }
    },
  }
}

export async function windowTitle(tb, pattern) {
  const r = await tb.x('xdotool', ['search', '--name', pattern, 'getwindowname'])
  return r.code === 0 ? r.stdout.split('\n')[0] : null
}

// ------------------------------------------------------------------ relay

export async function startRelay({ upstream, origins = [PAGE_ORIGIN], headers = ACCESS_HEADERS, acceptTimeout = 30, record = null }) {
  const token = randomBytes(16).toString('hex')
  const env = { ...process.env, RELAY_UPSTREAM: upstream, RELAY_TOKEN: token, RELAY_ORIGINS: origins.join(' '),
    RELAY_ACCEPT_TIMEOUT: String(acceptTimeout) }
  if (record) env.RELAY_RECORD = record
  headers.forEach((h, i) => { env[`RELAY_HEADER_${i + 1}`] = h })
  const child = spawn(PY, ['-I', '-B', path.join(ROOT, 'relay', 'relay.py')], { env, stdio: ['ignore', 'pipe', 'pipe'] })
  let out = ''
  let err = ''
  child.stderr.on('data', d => { err += d })
  const result = new Promise(resolve => {
    child.on('exit', code => {
      const last = out.trim().split('\n').filter(l => l.startsWith('{')).pop()
      resolve(last ? { exit: code, ...JSON.parse(last) } : { exit: code, error: err.slice(-400) })
    })
  })
  const port = await new Promise((resolve, reject) => {
    child.stdout.on('data', d => {
      out += d
      const m = /^port (\d+)$/m.exec(out)
      if (m) resolve(Number(m[1]))
    })
    child.on('exit', () => reject(new Error(`relay exited: ${err.slice(-400)}`)))
  })
  return { port, token, url: `ws://127.0.0.1:${port}/`, protocol: `shion.${token}`, result, child,
    kill: signal => { try { child.kill(signal) } catch { /* gone */ } } }
}

// ------------------------------------------------------------------ the page in Chromium

const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8' }

export async function launchChromium() {
  const { chromium } = playwright()
  const executablePath = process.env.WEBVNC_CHROMIUM || undefined
  // Chromium's Local Network Access checks block a page on a public origin (https://webvnc.test)
  // from opening ws://127.0.0.1 without asking the user. WebKit has no such check today; the
  // relay tests turn it off here (README: one reason to prefer HostChannel over the relay).
  const args = ['--disable-gpu']
  if (process.env.WEBVNC_KEEP_LNA !== '1') args.push('--disable-features=LocalNetworkAccessChecks')
  // a harmless unknown switch, so the measurements can find this browser's process tree
  const marker = `--webvnc-run=${process.pid}-${Date.now()}`
  args.push(marker)
  const browser = await chromium.launch({ executablePath, args })
  browser.webvncMarker = marker
  return browser
}

// The browser process of a launchChromium() browser (its renderer, GPU and utility processes are
// its descendants).
export async function browserPid(browser) {
  const { readdir, readFile } = await import('node:fs/promises')
  for (const name of await readdir('/proc')) {
    if (!/^\d+$/.test(name)) continue
    try {
      const cmd = (await readFile(`/proc/${name}/cmdline`, 'utf8')).split('\0')
      if (cmd.includes(browser.webvncMarker) && !cmd.some(a => a.startsWith('--type='))) return Number(name)
    } catch { /* gone */ }
  }
  return null
}

// Serves web/ at https://webvnc.test/ from disk (like the app's URL scheme handler serves its
// bundle: nothing comes from the network) and collects what the page posts to its host.
export async function openViewer(browser, { mac = false, viewport = { width: 1440, height: 900 }, channelHost = null } = {}) {
  const context = await browser.newContext({ viewport, deviceScaleFactor: 1 })
  if (mac) {
    await context.addInitScript(() => Object.defineProperty(Navigator.prototype, 'platform', { get: () => 'MacIntel' }))
  }
  await context.route(`${PAGE_ORIGIN}/**`, async route => {
    const url = new URL(route.request().url())
    const file = path.normalize(path.join(WEB, decodeURIComponent(url.pathname)))
    if (!file.startsWith(WEB + path.sep)) return route.fulfill({ status: 404, body: '' })
    try {
      const body = await readFile(file)
      return route.fulfill({ status: 200, body, contentType: MIME[path.extname(file)] || 'application/octet-stream' })
    } catch {
      return route.fulfill({ status: 404, body: '' })
    }
  })
  const messages = []
  const consoleLines = []
  await context.exposeBinding('shionTestHost', (_source, message) => {
    messages.push({ ...message, at: Date.now() })
    channelHost?.(message)
  })
  const page = await context.newPage()
  page.on('console', m => consoleLines.push(`${m.type()}: ${m.text()}`))
  page.on('pageerror', e => consoleLines.push(`pageerror: ${e.message}`))
  await page.goto(`${PAGE_ORIGIN}/viewer.html`)
  const ready = await until(() => messages.find(m => m.type === 'ready'), { what: 'the page', timeout: 15000 })
  const viewer = {
    page, context, messages, consoleLines, ready,
    call: (name, ...args) => page.evaluate(([n, a]) => window.shionVNC[n](...a), [name, args]),
    report: () => page.evaluate(() => window.shionVNC.report()),
    find: type => messages.filter(m => m.type === type),
    waitFor: (predicate, opts) => until(() => messages.find(predicate), opts),
    async close() { await context.close().catch(() => {}) },
  }
  return viewer
}

// Click the middle of the picture (focuses the IME textarea while holding the lease).
export async function clickScreen(viewer, x = 700, y = 450) {
  await viewer.page.mouse.click(x, y)
}

export function summary(results) {
  const failed = results.filter(r => !r.ok)
  for (const r of results) {
    console.log(`${r.ok ? 'PASS' : 'FAIL'}  ${r.name}${r.detail ? `  ${typeof r.detail === 'string' ? r.detail : JSON.stringify(r.detail)}` : ''}`)
  }
  console.log(`${results.length - failed.length}/${results.length} passed`)
  return failed.length === 0
}
