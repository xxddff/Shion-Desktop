// End-to-end checks of the web viewer on Linux: noVNC 1.7.0 in headless Chromium, reaching the
// rfb/ testbed (TigerVNC Xvnc + Hermes' own RFB filter behind a stand-in bridge that, like
// Cloudflare Access, refuses an upgrade without the service-token headers) through the loopback
// relay (option A) or through the app itself (HostChannel, option C).
//
//   RFB_TESTBED_PYTHON=~/testbed-venv/bin/python3 node webvnc/linux/e2e.mjs [--out DIR]
//
// Needs: Xvnc and the X tools of rfb/testbed (see rfb/README.md), google-chrome on the remote
// desktop (WEBVNC_REMOTE_CHROME), xclip, xdotool, Playwright (playwright or playwright-core).

import { spawn } from 'node:child_process'
import { writeFile, mkdir } from 'node:fs/promises'
import { readFileSync } from 'node:fs'
import { createHash } from 'node:crypto'
import path from 'node:path'
import {
  ROOT, PY, TESTBED, startTestbed, startRelay, launchChromium, openViewer, remoteChrome, windowTitle,
  until, sleep, summary, clickScreen,
} from './lib.mjs'
import { createChannelHost } from './channel-host.mjs'

const outDir = process.argv.includes('--out') ? process.argv[process.argv.indexOf('--out') + 1] : null
const results = []
const log = (...a) => console.log(new Date().toISOString().slice(11, 23), ...a)

async function check(name, fn) {
  const started = Date.now()
  try {
    const detail = await fn()
    results.push({ name, ok: true, detail, ms: Date.now() - started })
    log('PASS', name)
  } catch (error) {
    results.push({ name, ok: false, detail: String(error?.message ?? error).slice(0, 500), ms: Date.now() - started })
    log('FAIL', name, String(error?.message ?? error).slice(0, 300))
  }
}

function expect(cond, message) {
  if (!cond) throw new Error(message)
}

const hash12 = id => createHash('sha256').update(id).digest('hex').slice(0, 12)

function probeRelay(relay, after = false) {
  return new Promise(resolve => {
    const p = spawn(PY, ['-I', '-B', path.join(ROOT, 'linux', 'relay_probe.py'), ...(after ? ['--after'] : [])],
      { env: { ...process.env, RELAY_PORT: String(relay.port), RELAY_TOKEN: relay.token }, stdio: ['ignore', 'pipe', 'pipe'] })
    let out = ''
    p.stdout.on('data', d => { out += d })
    p.on('exit', () => { try { resolve(JSON.parse(out)) } catch { resolve({ error: out }) } })
  })
}

async function attach(browser, tb, viewerId, { viewOnly, mac = false, headers, transport = 'relay' } = {}) {
  const { url } = await tb.observe(viewerId)
  if (transport === 'channel') {
    const host = createChannelHost({ upstream: url, headers: headers ?? { 'CF-Access-Client-Id': 'test-client-id', 'CF-Access-Client-Secret': 'test-client-secret' } })
    const viewer = await openViewer(browser, { mac, channelHost: m => host.onPageMessage(m) })
    await viewer.call('connect', { transport: 'channel', viewOnly })
    host.start(viewer)
    return { viewer, host, upstream: url }
  }
  const relay = await startRelay({ upstream: url, ...(headers ? { headers } : {}) })
  const viewer = await openViewer(browser, { mac })
  await viewer.call('connect', { transport: 'relay', url: relay.url, protocols: [relay.protocol], viewOnly })
  return { viewer, relay, upstream: url }
}

const firstFrame = viewer => viewer.waitFor(m => m.type === 'firstFrame', { timeout: 15000, what: 'the first frame' })
const disconnected = (viewer, timeout = 10000) => viewer.waitFor(m => m.type === 'state' && m.state === 'disconnected', { timeout, what: 'the disconnect' })
const title = tb => windowTitle(tb, '^(T:|empty)')
const titleIs = (tb, want, timeout = 6000) => until(async () => (await title(tb)) === want, { timeout, what: `title ${JSON.stringify(want)}` }).catch(async () => {
  throw new Error(`remote title is ${JSON.stringify(await title(tb))}, wanted ${JSON.stringify(want)}`)
})

const tb = await startTestbed({ display: process.env.WEBVNC_DISPLAY || ':41', port: Number(process.env.WEBVNC_PORT || 8791), name: 'e2e' })
const browser = await launchChromium()
let chrome = null
try {
  await check('filter: noVNC side-button PointerEvent vs Hermes rfb_filter', async () => {
    const out = await new Promise(resolve => {
      const p = spawn(PY, ['-I', '-B', path.join(ROOT, 'linux', 'filter_check.py')], { stdio: ['ignore', 'pipe', 'inherit'] })
      let s = ''
      p.stdout.on('data', d => { s += d })
      p.on('exit', () => resolve(JSON.parse(s)))
    })
    expect(out['plain pointer + key'].intact, 'plain input should pass intact')
    expect(out['back button (noVNC, server offers -316)'].bridge === 'closes 1003', 'back button should break the stream')
    expect(!out['forward button (noVNC, server offers -316)'].intact, 'forward button should misframe')
    return out
  })

  await check('replay: the committed noVNC sample decodes to its recorded picture (what the macOS shell checks)', async () => {
    const meta = JSON.parse(readFileSync(path.join(ROOT, 'testdata', 'novnc-static.json'), 'utf8'))
    const replay = spawn(PY, ['-I', '-B', path.join(ROOT, 'linux', 'replay_messages.py'), path.join(ROOT, 'testdata', 'novnc-static.messages.z'),
      '--require-header', 'CF-Access-Client-Id', '--require-header', 'CF-Access-Client-Secret'], { stdio: ['ignore', 'pipe', 'inherit'] })
    let out = ''
    replay.stdout.on('data', d => { out += d })
    try {
      const port = Number((await until(() => /port (\d+)/.exec(out), { what: 'the replay server' }))[1])
      const relay = await startRelay({ upstream: `ws://127.0.0.1:${port}/api/display/ws?then=wait` })
      const viewer = await openViewer(browser)
      await viewer.call('connect', { transport: 'relay', url: relay.url, protocols: [relay.protocol], viewOnly: true })
      await firstFrame(viewer)
      let last = -1
      await until(async () => { const n = (await viewer.report()).bytesIn; const quiet = n === last; last = n; return quiet }, { every: 700, what: 'the replay to finish' })
      const picture = await viewer.call('pictureHash')
      await viewer.call('disconnect', true)
      await relay.result
      await viewer.close()
      await until(() => out.includes('client closed'), { what: 'the replay to see the close' })
      expect(picture.fnv1a === meta.picture.fnv1a, `picture ${picture.fnv1a}, recorded ${meta.picture.fnv1a}`)
      expect(out.includes('client closed 1000'), `replay saw: ${out}`)
      return { picture: picture.fnv1a, updates: meta.updates }
    } finally { replay.kill() }
  })

  await check('page: loads from the app origin, CSP holds', async () => {
    const viewer = await openViewer(browser)
    try {
      const blocked = await viewer.page.evaluate(async () => {
        const violations = []
        document.addEventListener('securitypolicyviolation', e => violations.push(e.violatedDirective))
        let fetchBlocked = false
        try { await fetch('https://example.com/') } catch { fetchBlocked = true }
        try { new WebSocket('ws://192.0.2.1:9/') } catch { /* some engines throw */ }
        const script = document.createElement('script')
        script.textContent = 'window.__inline = 1'
        document.head.append(script)
        await new Promise(r => setTimeout(r, 300))
        return { fetchBlocked, violations, inlineRan: !!window.__inline }
      })
      expect(blocked.fetchBlocked && !blocked.inlineRan, 'CSP did not block')
      return { ready: viewer.ready, ...blocked }
    } finally { await viewer.close() }
  })

  await check('relay: refuses other local clients; one page only', async () => {
    const { url } = await tb.observe('probe')
    const relay = await startRelay({ upstream: url })
    const before = await probeRelay(relay)
    const viewer = await openViewer(browser)
    await viewer.call('connect', { transport: 'relay', url: relay.url, protocols: [relay.protocol], viewOnly: true })
    await firstFrame(viewer)
    const after = await probeRelay(relay, true)
    await viewer.call('disconnect', true)
    const report = await relay.result
    await viewer.close()
    for (const [k, v] of Object.entries({ ...before, ...after })) expect(v.startsWith('refused'), `${k}: ${v}`)
    return { before, after, rejected: report.rejected, reasons: report.reject_reasons, pageOrigin: report.origin }
  })

  await check('watch: picture through the relay, stats', async () => {
    const { viewer, relay } = await attach(browser, tb, 'w-watch', { viewOnly: true })
    try {
      const ff = await firstFrame(viewer)
      await sleep(1500)
      const report = await viewer.report()
      expect(report.updates > 0, 'no updates')
      await viewer.call('disconnect', true)
      const r = await relay.result
      return { firstFrameMs: ff.ms, updates: report.updates, extendedClipboard: report.extendedClipboard,
        qemuKeys: report.qemuKeys, extendedMouseButtons: report.extendedMouseButtons, cursor: report.cursor,
        relayDown: r.down_bytes, relayUp: r.up_bytes, sentUpstream: r.sent_upstream }
    } finally { await viewer.close() }
  })

  chrome = await remoteChrome(tb, `file://${path.join(TESTBED, 'input.html')}`)
  await until(async () => (await title(tb)) === 'empty', { timeout: 20000, what: 'the remote Chrome' })
  await tb.x('xdotool', ['mousemove', '300', '200', 'click', '1'])

  // ---- holding the lease: keys, input method, paste
  await tb.acquire('holder')
  const held = await attach(browser, tb, 'holder', { viewOnly: false })
  try {
    await firstFrame(held.viewer)
    const page = held.viewer.page
    await clickScreen(held.viewer, 300, 200)
    await sleep(150)

    await check('holder: plain keys arrive (noVNC keyboard on the IME textarea)', async () => {
      await page.keyboard.type('Hello 123')
      await titleIs(tb, 'T:Hello 123')
      await page.keyboard.press('Control+a')
      await page.keyboard.press('Backspace')
      await titleIs(tb, 'T:')
      return 'Hello 123 typed, Ctrl+A Backspace cleared it'
    })

    await check('holder: Chinese, Japanese, emoji by clipboard + Ctrl+V', async () => {
      const text = '你好，云桌面\nクラウド 👋 ok'
      const r = await held.viewer.call('typeText', text)
      expect(r.ok, `typeText: ${r.reason}`)
      await titleIs(tb, 'T:你好，云桌面⏎クラウド 👋 ok')
      const clip = await tb.clipboard()
      expect(clip === text, `X clipboard: ${JSON.stringify(clip)}`)
      return { bytes: r.bytes }
    })
    await page.keyboard.press('Control+a')
    await page.keyboard.press('Backspace')
    await titleIs(tb, 'T:')

    await check('holder: input method — nothing sent while composing, the result pasted', async () => {
      const cdp = await page.context().newCDPSession(page)
      await cdp.send('Input.imeSetComposition', { text: 'nihao', selectionStart: 5, selectionEnd: 5 })
      await sleep(600)
      const during = await title(tb)
      expect(during === 'T:', `sent while composing: ${during}`)
      await cdp.send('Input.insertText', { text: '你好' })
      await titleIs(tb, 'T:你好')
      return 'composition "nihao" stayed local; committed 你好 arrived'
    })

    await check('holder: text inserted without composition (emoji picker)', async () => {
      await page.keyboard.insertText('👋🏽')
      await titleIs(tb, 'T:你好👋🏽')
      return 'ok'
    })

    await check('holder: paste event', async () => {
      await page.evaluate(() => {
        const dt = new DataTransfer()
        dt.setData('text/plain', ' 粘贴 ✓')
        document.getElementById('ime').dispatchEvent(new ClipboardEvent('paste', { clipboardData: dt, bubbles: true, cancelable: true }))
      })
      await titleIs(tb, 'T:你好👋🏽 粘贴 ✓')
      return 'ok'
    })

    await check('holder: keyboard layout — Xvnc types the character, not the key position', async () => {
      // noVNC sends QEMU extended key events (keysym + key position). An AZERTY "a" sits where
      // QWERTY has "q". Xvnc runs with RawKeyboard=0 (its default; Hermes' launcher.sh leaves it),
      // so it maps the keysym onto its own keymap and the remote gets "a" whatever the Mac's layout.
      await page.evaluate(() => {
        const ime = document.getElementById('ime')
        for (const type of ['keydown', 'keyup']) {
          ime.dispatchEvent(new KeyboardEvent(type, { key: 'a', code: 'KeyQ', keyCode: 65, bubbles: true, cancelable: true }))
        }
      })
      await titleIs(tb, 'T:你好👋🏽 粘贴 ✓a')
      return 'key "a" at the QWERTY "q" position arrived as "a"'
    })

    await check('holder: a dropped link keeps the lease', async () => {
      held.relay.kill('SIGKILL')
      await disconnected(held.viewer)
      await sleep(500)
      const lease = await tb.lease()
      expect(lease.holder === 'human' && lease.viewer_hash === hash12('holder'), `lease: ${JSON.stringify(lease)}`)
      return { pageSaw: held.viewer.find('state').pop()?.code, lease: lease.holder }
    })
  } finally { await held.viewer.close() }

  // ---- the same viewer id comes back (as after a network blip): ⌘ as Ctrl on a Mac
  await check('reconnect with the same viewer id: lease still ours; ⌘A → Ctrl+A on a Mac', async () => {
    const again = await attach(browser, tb, 'holder', { viewOnly: false, mac: true })
    try {
      await firstFrame(again.viewer)
      const page = again.viewer.page
      await clickScreen(again.viewer, 300, 200)
      await sleep(150)
      await page.keyboard.press('Meta+a')
      await page.keyboard.press('Backspace')
      await titleIs(tb, 'T:')
      await page.keyboard.type('mac')
      await titleIs(tb, 'T:mac')
      await again.viewer.call('disconnect', true)
      const r = await again.relay.result
      await sleep(300)
      const lease = await tb.lease()
      expect(r.sent_upstream === 1000 && lease.holder === 'agent', `hand-back: ${r.sent_upstream} ${lease.holder}`)
      return { handBack: r.sent_upstream, lease: lease.holder }
    } finally { await again.viewer.close() }
  })

  // ---- watching: input never reaches the remote, even if the page thinks it may send
  await tb.setClipboard('before')
  const watch = await attach(browser, tb, 'watcher', { viewOnly: true })
  try {
    await firstFrame(watch.viewer)
    await check('watcher: the bridge drops input even when the page sends it', async () => {
      await watch.viewer.call('setViewOnly', false)   // pretend: noVNC now sends input
      await clickScreen(watch.viewer, 300, 200)
      await sleep(100)
      await watch.viewer.page.keyboard.type('nope')
      const r = await watch.viewer.call('typeText', 'from a watcher')
      await sleep(1200)
      const t = await title(tb)
      const clip = await tb.clipboard()
      expect(t === 'T:mac' && clip === 'before', `title ${t}, clipboard ${clip}`)
      return { typeText: r.ok, title: t, clipboard: clip }
    })

    await check('watcher takes over on the same connection: paste works (capabilities sent while watching were dropped)', async () => {
      await tb.acquire('watcher')
      await sleep(400)   // the bridge re-reads the lease at most every 250 ms (here: on change)
      const r = await watch.viewer.call('typeText', '接管后')
      expect(r.ok, `typeText: ${r.reason}`)
      await titleIs(tb, 'T:mac接管后')
      return 'ok'
    })

    await check('another viewer takes over: 4000 reaches the page through the relay', async () => {
      await tb.acquire('other')
      const d = await disconnected(watch.viewer)
      const r = await watch.relay.result
      expect(d.code === 4000 && r.sent_page === 4000, `page ${d.code}, relay ${JSON.stringify(r.sent_page)}`)
      return { pageCode: d.code, reason: d.reason }
    })
  } finally { await watch.viewer.close() }
  await tb.release()

  await check('spent ticket: 4401 reaches the page', async () => {
    const first = await attach(browser, tb, 't1', { viewOnly: true })
    await firstFrame(first.viewer)
    await first.viewer.call('disconnect', true)
    await first.relay.result
    await first.viewer.close()
    const relay = await startRelay({ upstream: first.upstream })
    const viewer = await openViewer(browser)
    await viewer.call('connect', { transport: 'relay', url: relay.url, protocols: [relay.protocol], viewOnly: true })
    const d = await disconnected(viewer)
    await viewer.close()
    expect(d.code === 4401, `got ${d.code}`)
    return { code: d.code, reason: d.reason }
  })

  await check('no Access headers: upgrade refused (403), the page gets 4403', async () => {
    const { viewer, relay } = await attach(browser, tb, 'noheaders', { viewOnly: true, headers: [] })
    const d = await disconnected(viewer)
    const r = await relay.result
    await viewer.close()
    expect(d.code === 4403 && r.upstream_refused === 403, `page ${d.code}, upstream ${r.upstream_refused}`)
    return { code: d.code, upstream: r.upstream_refused }
  })

  // ---- option C: no socket in the page at all
  await check('HostChannel: picture, typing and hand-back without any socket in the page', async () => {
    await tb.acquire('chan')
    const { viewer, host } = await attach(browser, tb, 'chan', { viewOnly: false, transport: 'channel' })
    try {
      const ff = await firstFrame(viewer)
      await clickScreen(viewer, 300, 200)
      await sleep(150)
      await viewer.page.keyboard.press('Control+a')
      await viewer.page.keyboard.press('Backspace')
      await titleIs(tb, 'T:')
      const r = await viewer.call('typeText', '通道 チャネル ✓')
      expect(r.ok, `typeText: ${r.reason}`)
      await titleIs(tb, 'T:通道 チャネル ✓')
      const report = await viewer.report()
      await viewer.call('disconnect', true)
      await disconnected(viewer)
      await sleep(400)
      const lease = await tb.lease()
      expect(lease.holder === 'agent', `lease ${lease.holder}`)
      return { firstFrameMs: ff.ms, updates: report.updates, batches: host.stats.batches,
        bytesDown: host.stats.bytesDown, bytesUp: host.stats.bytesUp, sentClose: host.stats.sentClose }
    } finally { await viewer.close() }
  })

  await check('HostChannel: 4000 reaches the page', async () => {
    await tb.acquire('chan2')
    const { viewer } = await attach(browser, tb, 'chan2', { viewOnly: false, transport: 'channel' })
    try {
      await firstFrame(viewer)
      await tb.acquire('someone-else')
      const d = await disconnected(viewer)
      expect(d.code === 4000, `got ${d.code}`)
      return { code: d.code }
    } finally { await viewer.close() }
  })
  await tb.release()
} finally {
  await chrome?.stop()
  await browser.close()
  await tb.stop()
}

const ok = summary(results)
if (outDir) {
  await mkdir(outDir, { recursive: true })
  await writeFile(path.join(outDir, 'e2e.json'), JSON.stringify(results, null, 2))
}
process.exit(ok ? 0 : 1)
