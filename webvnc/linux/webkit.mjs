// The web viewer in WebKitGTK (linux/webkitgtk_host.py): the same engine family as WKWebView, the
// same window.webkit.messageHandlers bridge and a custom URL scheme. Not the Mac's graphics stack,
// process model or sandbox, so this narrows the gap to the macOS shell, it does not close it.
//
//   WEBVNC_WK_PYTHON=python3-with-gi-and-websockets RFB_TESTBED_PYTHON=… node webvnc/linux/webkit.mjs \
//       [--scroll-sample FILE] [--out DIR]
//
// Needs Xvfb, openbox, gir1.2-webkit-6.0, python3-gi; the rfb/ testbed as for e2e.mjs.

import { spawn } from 'node:child_process'
import { writeFile, mkdir } from 'node:fs/promises'
import { existsSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { ROOT, TESTBED, PY, startTestbed, startRelay, remoteChrome, windowTitle, until, sleep, summary } from './lib.mjs'

const arg = (name, fallback) => (process.argv.includes(name) ? process.argv[process.argv.indexOf(name) + 1] : fallback)
const OUT = arg('--out', null)
const SCROLL = arg('--scroll-sample', null)
const WKPY = process.env.WEBVNC_WK_PYTHON || 'python3'
const DISPLAY = process.env.WEBVNC_WK_DISPLAY || ':60'
const results = []
const log = (...a) => console.log(new Date().toISOString().slice(11, 23), ...a)

async function check(name, fn) {
  try {
    const detail = await fn()
    results.push({ name, ok: true, detail })
    log('PASS', name)
  } catch (error) {
    results.push({ name, ok: false, detail: String(error?.message ?? error).slice(0, 600) })
    log('FAIL', name, String(error?.message ?? error).slice(0, 300))
  }
}

function expect(cond, message) { if (!cond) throw new Error(message) }

function host(args, extraEnv = {}, timeoutMs = 90000) {
  return new Promise(resolve => {
    const env = { ...process.env, DISPLAY, GDK_BACKEND: 'x11', NO_AT_BRIDGE: '1', GTK_A11Y: 'none', ...extraEnv }
    const p = spawn(WKPY, ['-I', path.join(ROOT, 'linux', 'webkitgtk_host.py'), ...args], { env, stdio: ['ignore', 'pipe', 'pipe'] })
    let out = ''
    let err = ''
    p.stdout.on('data', d => { out += d })
    p.stderr.on('data', d => { err += d })
    const timer = setTimeout(() => p.kill('SIGKILL'), timeoutMs)
    p.on('exit', code => {
      clearTimeout(timer)
      const line = out.trim().split('\n').filter(l => l.startsWith('{')).pop()
      try { resolve({ exit: code, ...JSON.parse(line) }) } catch { resolve({ exit: code, error: `no result: ${err.slice(-500)}` }) }
    })
  })
}

function replayServer(sample) {
  const p = spawn(PY, ['-I', '-B', path.join(ROOT, 'linux', 'replay_messages.py'), sample,
    '--require-header', 'CF-Access-Client-Id', '--require-header', 'CF-Access-Client-Secret'], { stdio: ['ignore', 'pipe', 'inherit'] })
  let out = ''
  p.stdout.on('data', d => { out += d })
  return until(() => /port (\d+)/.exec(out), { what: 'the replay server' }).then(m => ({ port: Number(m[1]), stop: () => p.kill() }))
}

// an X server for the WebKitGTK window (not the testbed's: its picture would feed back into itself),
// with a window manager so that the window gets the keyboard focus
let xvfb = null
let wm = null
if (!existsSync(`/tmp/.X11-unix/X${DISPLAY.slice(1)}`)) {
  xvfb = spawn('Xvfb', [DISPLAY, '-screen', '0', '1600x1000x24', '-nolisten', 'tcp'], { stdio: 'ignore' })
  await sleep(1000)
  wm = spawn('openbox', [], { env: { ...process.env, DISPLAY }, stdio: 'ignore' })
  wm.on('error', () => { wm = null })   // no openbox: the key test then fails, the rest runs
  await sleep(500)
}

const accessEnv = { WEBVNC_HEADER_1: 'CF-Access-Client-Id: test-client-id', WEBVNC_HEADER_2: 'CF-Access-Client-Secret: test-client-secret' }
const tb = await startTestbed({ display: ':46', port: 8796, name: 'wk' })
let chrome = null
try {
  await check('webkitgtk: the page from a custom scheme (ES modules, secure context, CSP)', async () => {
    const r = await host(['--check'])
    expect(r.ready && r.csp?.fetchBlocked && r.csp?.inlineRan === false, JSON.stringify(r))
    const insecure = await host(['--check', '--insecure-scheme'])
    return { engine: r.engine, ready: r.ready, csp: r.csp, notRegisteredAsSecure: insecure.ready }
  })

  chrome = await remoteChrome(tb, `file://${path.join(TESTBED, 'input.html')}`)
  await until(async () => (await windowTitle(tb, '^empty$')) !== null, { timeout: 20000, what: 'the remote Chrome' })
  await tb.x('xdotool', ['mousemove', '300', '200', 'click', '1'])

  // (Real key events are checked in Chromium and on macOS: keys typed with xdotool into the GTK4
  // window under Xvfb never reached the page, a focus matter of this setup, not of the page.)
  await check('webkitgtk: relay, holder — clipboard + Ctrl+V reaches the remote', async () => {
    await tb.acquire('wk-holder')
    const { url } = await tb.observe('wk-holder')
    const relay = await startRelay({ upstream: url, origins: ['shion-webvnc://app'] })
    const r = await host(['--relay', relay.url, '--protocol', relay.protocol, '--hold', '--type', '你好 クラウド 👋', '--seconds', '4'])
    const rr = await relay.result
    const title = await windowTitle(tb, '^(T:|empty)')
    expect(title === 'T:你好 クラウド 👋', `remote title ${JSON.stringify(title)}; host ${JSON.stringify(r).slice(0, 400)}`)
    return { firstFrameMs: r.firstFrameMs, typed: r.typed, origin: rr.origin, sentUpstream: rr.sent_upstream }
  })

  await check('webkitgtk: HostChannel, holder — no socket in the page', async () => {
    await tb.acquire('wk-holder')   // the relay test closed with 1000, which handed the lease back
    const { url } = await tb.observe('wk-holder')
    const r = await host(['--channel', '--hold', '--type', ' ✓', '--seconds', '3'], { ...accessEnv, WEBVNC_UPSTREAM: url })
    const title = await windowTitle(tb, '^(T:|empty)')
    expect(title === 'T:你好 クラウド 👋 ✓', `remote title ${JSON.stringify(title)}; host ${JSON.stringify(r).slice(0, 400)}`)
    return { firstFrameMs: r.firstFrameMs, typed: r.typed, channel: r.channel }
  })
  await tb.release()

  if (SCROLL && existsSync(SCROLL)) {
    const meta = JSON.parse(readFileSync(SCROLL.replace(/\.messages\.z$/, '.json'), 'utf8'))
    const replay = await replayServer(SCROLL)
    for (const transport of ['relay', 'channel']) {
      await check(`webkitgtk: decode a recorded Chrome scroll (${meta.updates} updates, ${(meta.bytes / 1e6).toFixed(1)} MB) through the ${transport}`, async () => {
        const url = `ws://127.0.0.1:${replay.port}/api/display/ws?then=wait`
        let r
        if (transport === 'relay') {
          const relay = await startRelay({ upstream: url, origins: ['shion-webvnc://app'] })
          r = await host(['--relay', relay.url, '--protocol', relay.protocol, '--until-updates', String(meta.updates), '--timeout', '120'], {}, 150000)
          await relay.result
        } else {
          r = await host(['--channel', '--until-updates', String(meta.updates), '--timeout', '120'], { ...accessEnv, WEBVNC_UPSTREAM: url }, 150000)
        }
        expect(r.decode?.updates >= meta.updates, JSON.stringify(r).slice(0, 400))
        return { ...r.decode, channel: r.channel }
      })
    }
    replay.stop()
  }
} finally {
  await chrome?.stop()
  await tb.stop()
  wm?.kill()
  xvfb?.kill()
}

const ok = summary(results)
if (OUT) {
  await mkdir(OUT, { recursive: true })
  await writeFile(path.join(OUT, 'webkitgtk.json'), JSON.stringify(results, null, 2))
}
process.exit(ok ? 0 : 1)
