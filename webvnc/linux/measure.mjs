// Native (rfb-probe, ZRLE) against noVNC in headless Chromium (Tight + JPEG quality 7 as the official
// desktop app asks for, and ZRLE for comparison), on the same testbed scenes:
//
//   static        the static testbed scene, 5 s
//   scroll        a remote Chrome scrolling a long article with photo-like pictures, 5 s of wheel
//   scroll-150ms  the same with 150 ms added round trip (the bridge delays both directions)
//   static-150ms  first picture over a 150 ms round trip
//
// Each run: connect, first picture, (scroll), settle, disconnect. Per run: time to first picture,
// FramebufferUpdates, bytes down / up, CPU seconds of the client (the whole Chromium process tree
// for noVNC: renderer, GPU and browser processes), of the relay, and of Xvnc (the encoder side).
//
//   RFB_TESTBED_PYTHON=… RFB_PROBE=…/rfb-probe node webvnc/linux/measure.mjs [--repeat 3] [--out DIR]
//       [--only scroll,static] [--clients native,novnc-relay,novnc-channel,novnc-zrle,native-nopipe]

import { spawn } from 'node:child_process'
import { readFile, readdir, writeFile, mkdir } from 'node:fs/promises'
import path from 'node:path'
import os from 'node:os'
import {
  ROOT, startTestbed, startRelay, launchChromium, browserPid, openViewer, remoteChrome, windowTitle, until, sleep,
} from './lib.mjs'
import { createChannelHost } from './channel-host.mjs'

const arg = (name, fallback) => (process.argv.includes(name) ? process.argv[process.argv.indexOf(name) + 1] : fallback)
const REPEAT = Number(arg('--repeat', '3'))
const OUT = arg('--out', null)
const ONLY = arg('--only', 'static,scroll,scroll-150ms,static-150ms').split(',')
const CLIENTS = arg('--clients', 'native,novnc-relay,novnc-channel,novnc-zrle').split(',')
const PROBE = process.env.RFB_PROBE || path.join(ROOT, '..', 'rfb', '.build', 'release', 'rfb-probe')
const HZ = 100
const SCROLL_S = 5
// the native client's list (rfb/Sources/RFB/Client.swift), for noVNC-with-ZRLE
const NATIVE_ENCODINGS = [16, 1, 0, -223, -308, -224, -312, -313, -1063131698]

const log = (...a) => console.log(new Date().toISOString().slice(11, 23), ...a)

// ------------------------------------------------------------------ CPU from /proc

async function cpuOf(pid) {
  try {
    const stat = await readFile(`/proc/${pid}/stat`, 'utf8')
    const f = stat.slice(stat.lastIndexOf(')') + 2).split(' ')
    return (Number(f[11]) + Number(f[12])) / HZ   // utime + stime
  } catch { return 0 }
}

async function treeOf(root) {
  const parents = new Map()
  for (const name of await readdir('/proc')) {
    if (!/^\d+$/.test(name)) continue
    try {
      const stat = await readFile(`/proc/${name}/stat`, 'utf8')
      parents.set(Number(name), Number(stat.slice(stat.lastIndexOf(')') + 2).split(' ')[1]))
    } catch { /* gone */ }
  }
  const out = [root]
  for (let i = 0; i < out.length; i++) for (const [pid, ppid] of parents) if (ppid === out[i]) out.push(pid)
  return out
}

async function cpuOfTree(root) {
  let total = 0
  for (const pid of await treeOf(root)) total += await cpuOf(pid)
  return total
}

async function pidsByName(name) {
  const out = []
  for (const entry of await readdir('/proc')) {
    if (!/^\d+$/.test(entry)) continue
    try { if ((await readFile(`/proc/${entry}/comm`, 'utf8')).trim() === name) out.push(Number(entry)) } catch { /* gone */ }
  }
  return out
}

// ------------------------------------------------------------------ remote actions

async function scrollTop(tb) {
  await tb.x('xdotool', ['mousemove', '700', '450', 'key', '--clearmodifiers', 'ctrl+Home'])
  await sleep(1200)
}

function scroll(tb, seconds) {
  // one wheel notch every 100 ms, pointer over the article
  return tb.x('xdotool', ['mousemove', '700', '450', 'click', '--repeat', String(seconds * 10), '--delay', '100', '5'], { timeout: (seconds + 5) * 1000 })
}

// ------------------------------------------------------------------ clients

// rfb-probe stops by itself after --seconds (counted from its first picture) and prints its totals.
async function runNativeCounted(tb, scene, opts) {
  const { url } = await tb.observe(`m-native-${Date.now()}`)
  const xvnc = (await pidsByName('Xvnc'))[0]
  const xvnc0 = await cpuOf(xvnc)
  const seconds = scene.seconds
  const args = [url, '-H', 'CF-Access-Client-Id: @env:CF_ID', '-H', 'CF-Access-Client-Secret: @env:CF_SECRET',
    '--seconds', String(seconds), '--keepalive', '0', '--out', path.join(os.tmpdir(), `wv-probe-${process.pid}`)]
  if (opts?.pipeline === false) args.push('--no-pipeline')
  const started = Date.now()
  const child = spawn(PROBE, args, { env: { ...process.env, CF_ID: 'test-client-id', CF_SECRET: 'test-client-secret' }, stdio: ['ignore', 'ignore', 'pipe'] })
  let err = ''
  child.stderr.on('data', d => { err += d })
  const exited = new Promise(resolve => child.on('exit', resolve))
  // rfb-probe prints its events (first picture included) only when it ends; "connected" is live,
  // and the first picture follows within milliseconds on this testbed.
  await until(() => /connected to .* in \d+ ms/.test(err), { timeout: 20000, what: 'rfb-probe connected' })
  const duringDone = scene.during()
  // sample the CPU just before rfb-probe's own end (it then encodes a PNG, which is not viewing)
  let cpu = 0
  const sampler = setInterval(async () => { const c = await cpuOf(child.pid); if (c) cpu = c }, 50)
  await exited
  clearInterval(sampler)
  await duringDone
  const xvncCpu = (await cpuOf(xvnc)) - xvnc0
  const m = /updates: (\d+), received (\d+) bytes, sent (\d+)/.exec(err)
  return {
    firstFrameMs: Number(/first picture after (\d+) ms/.exec(err)?.[1]),
    updates: Number(m?.[1]), bytesDown: Number(m?.[2]), bytesUp: Number(m?.[3]),
    cpu: Math.round(cpu * 100) / 100, xvncCpu: Math.round(xvncCpu * 100) / 100, wallMs: Date.now() - started,
  }
}

async function runNoVNC(tb, browser, scene, { transport = 'relay', encodings } = {}) {
  const viewerId = `m-novnc-${Date.now()}`
  const { url } = await tb.observe(viewerId)
  const xvnc = (await pidsByName('Xvnc'))[0]
  const browserPid = browser.__pid
  let relay = null
  let host = null
  let viewer
  if (transport === 'channel') {
    host = createChannelHost({ upstream: url, headers: { 'CF-Access-Client-Id': 'test-client-id', 'CF-Access-Client-Secret': 'test-client-secret' } })
    viewer = await openViewer(browser, { channelHost: m => host.onPageMessage(m) })
  } else {
    relay = await startRelay({ upstream: url })
    viewer = await openViewer(browser)
  }
  await sleep(300)
  const cpu0 = await cpuOfTree(browserPid)
  const xvnc0 = await cpuOf(xvnc)
  const nodeCpu0 = process.cpuUsage()
  if (transport === 'channel') {
    await viewer.call('connect', { transport: 'channel', viewOnly: true, encodings })
    host.start(viewer)
  } else {
    await viewer.call('connect', { transport: 'relay', url: relay.url, protocols: [relay.protocol], viewOnly: true, encodings })
  }
  await viewer.waitFor(m => m.type === 'firstFrame', { timeout: 20000, what: 'noVNC first frame' })
  await scene.during()
  const report = await viewer.report()
  const cpu = (await cpuOfTree(browserPid)) - cpu0
  const xvncCpu = (await cpuOf(xvnc)) - xvnc0
  const nodeCpu = process.cpuUsage(nodeCpu0)
  await viewer.call('disconnect', true)
  let relayReport = null
  if (relay) relayReport = await relay.result
  await sleep(200)
  await viewer.close()
  return {
    firstFrameMs: report.firstFrameMs, updates: report.updates,
    bytesDown: relay ? relayReport.down_bytes : host.stats.bytesDown,
    bytesUp: relay ? relayReport.up_bytes : host.stats.bytesUp,
    cpu: Math.round(cpu * 100) / 100,
    // the app's side of the bytes: the relay process, or (channel) this Node process's share
    hostCpu: relay ? relayReport.cpu_s : Math.round((nodeCpu.user + nodeCpu.system) / 1e4) / 100,
    xvncCpu: Math.round(xvncCpu * 100) / 100,
    batches: host?.stats.batches,
  }
}

// ------------------------------------------------------------------ scenes

function scenes(tb) {
  return {
    static: { seconds: 5, async setup() {}, async before() {}, during: () => sleep(5000) },
    scroll: {
      seconds: SCROLL_S + 1.5,
      async before() { await scrollTop(tb) },
      // settle 0.5 s, scroll, settle 1 s
      during: async () => { await sleep(500); await scroll(tb, SCROLL_S); await sleep(1000) },
    },
  }
}

const SCENARIOS = {
  'static': { latencyMs: 0, scene: 'static' },
  'static-150ms': { latencyMs: 150, scene: 'static' },
  'scroll': { latencyMs: 0, scene: 'scroll' },
  'scroll-150ms': { latencyMs: 150, scene: 'scroll' },
}

function median(values) {
  const v = values.filter(x => typeof x === 'number' && !Number.isNaN(x)).sort((a, b) => a - b)
  if (!v.length) return null
  const mid = Math.floor(v.length / 2)
  return v.length % 2 ? v[mid] : Math.round((v[mid - 1] + v[mid]) / 2 * 100) / 100
}

const all = {}
for (const [index, name] of ONLY.entries()) {
  const scenario = SCENARIOS[name]
  if (!scenario) continue
  log(`== ${name}`)
  const tb = await startTestbed({ display: ':43', port: 8793, scene: 'static', latencyMs: scenario.latencyMs, name: `m${index}` })
  const browser = await launchChromium()
  browser.__pid = await browserPid(browser)
  if (!browser.__pid) throw new Error('cannot find the Chromium process')
  let chrome = null
  try {
    const sc = scenes(tb)[scenario.scene]
    if (scenario.scene === 'scroll') {
      chrome = await remoteChrome(tb, `file://${path.join(ROOT, 'linux', 'scenes', 'article.html')}`, { width: 1440, height: 900, name: 'article' })
      await until(async () => (await windowTitle(tb, '^article ready')) !== null, { timeout: 30000, what: 'the article' })
      await sleep(1500)
    }
    const runs = {}
    for (let r = 0; r < REPEAT; r++) {
      for (const client of CLIENTS) {
        await sc.before()
        let result
        try {
          if (client === 'native') result = await runNativeCounted(tb, sc)
          else if (client === 'native-nopipe') result = await runNativeCounted(tb, sc, { pipeline: false })
          else if (client === 'novnc-relay') result = await runNoVNC(tb, browser, sc)
          else if (client === 'novnc-channel') result = await runNoVNC(tb, browser, sc, { transport: 'channel' })
          else if (client === 'novnc-zrle') result = await runNoVNC(tb, browser, sc, { encodings: NATIVE_ENCODINGS })
        } catch (error) {
          result = { error: String(error?.message ?? error).slice(0, 200) }
        }
        log(name, client, JSON.stringify(result))
        ;(runs[client] ??= []).push(result)
        await sleep(500)
      }
    }
    all[name] = {}
    for (const [client, list] of Object.entries(runs)) {
      const keys = [...new Set(list.flatMap(Object.keys))].filter(k => k !== 'error')
      all[name][client] = Object.fromEntries(keys.map(k => [k, median(list.map(x => x[k]))]))
      all[name][client].runs = list.length
      all[name][client].errors = list.filter(x => x.error).map(x => x.error)
    }
    if (OUT) {
      await mkdir(OUT, { recursive: true })
      await writeFile(path.join(OUT, `measure-${name}.json`), JSON.stringify({ when: new Date().toISOString(), cpus: os.cpus().length, repeat: REPEAT, median: all[name], runs }, null, 2))
    }
  } finally {
    await chrome?.stop()
    await browser.close()
    await tb.stop()
  }
}

console.log(JSON.stringify(all, null, 2))
if (OUT) {
  await mkdir(OUT, { recursive: true })
  await writeFile(path.join(OUT, 'measure.json'), JSON.stringify({ when: new Date().toISOString(), cpus: os.cpus().length, repeat: REPEAT, results: all }, null, 2))
}
