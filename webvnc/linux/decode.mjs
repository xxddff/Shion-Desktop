// Decode throughput: a recorded noVNC session (NAME.messages.z with NAME.json, as record-sample.mjs
// writes them; CI hands its scroll recording to the macOS shell) fed to the page as fast as it takes
// it, through the relay (option A) and through the channel (option C), in headless Chromium and in
// WebKitGTK. Timed from connect until the page has processed every update (polled every 50 ms, as
// the macOS shell does). CPU: the engine's whole process tree; its web-content process alone
// (Chromium's renderer, WebKitWebProcess: what the macOS shell counts as WebContent); its UI process
// alone (Chromium's browser process; WebKitGTK's is the host, which also runs the channel); the
// relay process; and, for Chromium's channel, this Node process. Median of --repeat runs.
//
//   node webvnc/linux/decode.mjs SAMPLE.messages.z [--engines chrome,webkitgtk] [--repeat 3] [--out FILE]
//
// WebKitGTK needs Xvfb, gir1.2-webkit-6.0 and WEBVNC_WK_PYTHON (python3 with gi and websockets).

import { spawn } from 'node:child_process'
import { readFile, readdir, writeFile, mkdir } from 'node:fs/promises'
import { existsSync, readFileSync } from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { ROOT, PY, startRelay, launchChromium, browserPid, openViewer, until, sleep } from './lib.mjs'
import { createChannelHost } from './channel-host.mjs'

const arg = (name, fallback) => (process.argv.includes(name) ? process.argv[process.argv.indexOf(name) + 1] : fallback)
const SAMPLE = process.argv[2]
const ENGINES = arg('--engines', 'chrome,webkitgtk').split(',')
const REPEAT = Number(arg('--repeat', '3'))
const OUT = arg('--out', null)
const WKPY = process.env.WEBVNC_WK_PYTHON || 'python3'
const DISPLAY = process.env.WEBVNC_WK_DISPLAY || ':62'
const HZ = 100
const log = (...a) => console.log(new Date().toISOString().slice(11, 23), ...a)

if (!SAMPLE || !existsSync(SAMPLE)) {
  console.error('usage: decode.mjs SAMPLE.messages.z [--engines chrome,webkitgtk] [--repeat N] [--out FILE]')
  process.exit(2)
}
const meta = JSON.parse(readFileSync(SAMPLE.replace(/\.messages\.z$/, '.json'), 'utf8'))
const median = xs => [...xs].sort((a, b) => a - b)[Math.floor(xs.length / 2)]
const round = (x, n = 2) => (x == null ? null : Number(x.toFixed(n)))

// ------------------------------------------------------------------ CPU from /proc

async function processes() {
  const out = new Map()
  for (const name of await readdir('/proc')) {
    if (!/^\d+$/.test(name)) continue
    try {
      const stat = await readFile(`/proc/${name}/stat`, 'utf8')
      const f = stat.slice(stat.lastIndexOf(')') + 2).split(' ')
      // (zygote children rewrite their title: one string with spaces, not NUL-separated arguments)
      const cmd = await readFile(`/proc/${name}/cmdline`, 'utf8')
      out.set(Number(name), { ppid: Number(f[1]), cpu: (Number(f[11]) + Number(f[12])) / HZ, renderer: /(^|[\s\0])--type=renderer([\s\0]|$)/.test(cmd) })
    } catch { /* gone */ }
  }
  return out
}

// {total, web, ui} CPU seconds of `root` and its descendants (web: the renderers; ui: the browser
// process itself)
async function chromeCPU(root) {
  const procs = await processes()
  const tree = [root]
  for (let i = 0; i < tree.length; i++) for (const [pid, p] of procs) if (p.ppid === tree[i]) tree.push(pid)
  let total = 0
  let web = 0
  for (const pid of tree) {
    const p = procs.get(pid)
    if (!p) continue
    total += p.cpu
    if (p.renderer) web += p.cpu
  }
  return { total, web, ui: procs.get(root)?.cpu ?? 0 }
}

// ------------------------------------------------------------------ the recording

function replayServer() {
  const p = spawn(PY, ['-I', '-B', path.join(ROOT, 'linux', 'replay_messages.py'), SAMPLE,
    '--require-header', 'CF-Access-Client-Id', '--require-header', 'CF-Access-Client-Secret'], { stdio: ['ignore', 'pipe', 'inherit'] })
  let out = ''
  p.stdout.on('data', d => { out += d })
  return until(() => /port (\d+)/.exec(out), { what: 'the replay server' })
    .then(m => ({ url: `ws://127.0.0.1:${Number(m[1])}/api/display/ws?then=wait`, stop: () => p.kill() }))
}

const HEADERS = { 'CF-Access-Client-Id': 'test-client-id', 'CF-Access-Client-Secret': 'test-client-secret' }

// ------------------------------------------------------------------ Chromium

async function chromeOnce(browser, pid, transport, upstream) {
  const host = transport === 'channel' ? createChannelHost({ upstream, headers: HEADERS }) : null
  const viewer = await openViewer(browser, host ? { channelHost: m => host.onPageMessage(m) } : {})
  const relay = transport === 'relay' ? await startRelay({ upstream }) : null
  const cpu0 = await chromeCPU(pid)
  const node0 = process.cpuUsage()
  const t0 = Date.now()
  if (relay) {
    await viewer.call('connect', { transport: 'relay', url: relay.url, protocols: [relay.protocol], viewOnly: true })
  } else {
    await viewer.call('connect', { transport: 'channel', viewOnly: true })
    host.start(viewer)
  }
  let r
  let last = -1
  let since = Date.now()
  for (;;) {
    r = await viewer.report()
    if (r.updates >= meta.updates) break
    if (r.updates !== last) { last = r.updates; since = Date.now() } else if (Date.now() - since > 3000) break
    await sleep(50)
  }
  const seconds = (Date.now() - t0) / 1000
  const cpu = await chromeCPU(pid)
  const node = process.cpuUsage(node0)
  await viewer.call('disconnect', true)
  const relayResult = relay ? await relay.result : null
  await viewer.close()
  return {
    updates: r.updates, bytesIn: r.bytesIn, seconds,
    engineCPU: cpu.total - cpu0.total, webProcessCPU: cpu.web - cpu0.web, uiProcessCPU: cpu.ui - cpu0.ui,
    relayCPU: relayResult ? relayResult.cpu_s : null,
    // the channel's App side here is this Node process: the WebSocket and the CDP calls into the page
    channelCPU: relay ? null : (node.user + node.system) / 1e6,
  }
}

// ------------------------------------------------------------------ WebKitGTK

function wkHost(args, extraEnv = {}) {
  return new Promise(resolve => {
    const env = { ...process.env, DISPLAY, GDK_BACKEND: 'x11', NO_AT_BRIDGE: '1', GTK_A11Y: 'none', ...extraEnv }
    const p = spawn(WKPY, ['-I', path.join(ROOT, 'linux', 'webkitgtk_host.py'), ...args], { env, stdio: ['ignore', 'pipe', 'pipe'] })
    let out = ''
    let err = ''
    p.stdout.on('data', d => { out += d })
    p.stderr.on('data', d => { err += d })
    const timer = setTimeout(() => p.kill('SIGKILL'), 150000)
    p.on('exit', code => {
      clearTimeout(timer)
      const line = out.trim().split('\n').filter(l => l.startsWith('{')).pop()
      try { resolve({ exit: code, ...JSON.parse(line) }) } catch { resolve({ exit: code, error: `no result: ${err.slice(-400)}` }) }
    })
  })
}

async function webkitOnce(transport, upstream) {
  let r
  if (transport === 'relay') {
    const relay = await startRelay({ upstream, origins: ['shion-webvnc://app'] })
    r = await wkHost(['--relay', relay.url, '--protocol', relay.protocol, '--until-updates', String(meta.updates), '--timeout', '120'])
    const relayResult = await relay.result
    if (r.decode) r.decode.relayCPU = relayResult.cpu_s
  } else {
    r = await wkHost(['--channel', '--until-updates', String(meta.updates), '--timeout', '120'], {
      WEBVNC_UPSTREAM: upstream,
      WEBVNC_HEADER_1: 'CF-Access-Client-Id: test-client-id', WEBVNC_HEADER_2: 'CF-Access-Client-Secret: test-client-secret',
    })
  }
  if (!r.decode) throw new Error(JSON.stringify(r).slice(0, 400))
  // the channel's App side (the WebSocket, callAsyncJavaScript) runs in the UI process, next to
  // GTK's drawing of the web view
  const { cpu, hostCPU, ...rest } = r.decode
  return { ...rest, engineCPU: cpu, uiProcessCPU: hostCPU, relayCPU: rest.relayCPU ?? null, channelCPU: null }
}

// ------------------------------------------------------------------ run

const replay = await replayServer()
const runs = []
const summary = {}
let xvfb = null
try {
  for (const engine of ENGINES) {
    let browser = null
    let pid = null
    if (engine === 'chrome') {
      browser = await launchChromium()
      pid = await browserPid(browser)
    } else if (engine === 'webkitgtk' && !existsSync(`/tmp/.X11-unix/X${DISPLAY.slice(1)}`)) {
      xvfb = spawn('Xvfb', [DISPLAY, '-screen', '0', '1600x1000x24', '-nolisten', 'tcp'], { stdio: 'ignore' })
      await sleep(1000)
    }
    try {
      for (const transport of ['relay', 'channel']) {
        const mine = []
        for (let i = 0; i < REPEAT; i++) {
          const r = engine === 'chrome' ? await chromeOnce(browser, pid, transport, replay.url) : await webkitOnce(transport, replay.url)
          if (r.updates < meta.updates) throw new Error(`${engine} ${transport}: only ${r.updates} of ${meta.updates} updates`)
          mine.push(r)
          runs.push({ engine, transport, ...r })
          log(engine, transport, `${r.seconds.toFixed(2)} s`, ...['engineCPU', 'webProcessCPU', 'uiProcessCPU', 'relayCPU', 'channelCPU']
            .filter(k => r[k] != null).map(k => `${k} ${r[k].toFixed(2)} s`))
        }
        const med = k => (mine[0][k] == null ? null : round(median(mine.map(r => r[k]))))
        summary[`${engine} ${transport}`] = {
          seconds: med('seconds'),
          MBps: round(meta.bytes / 1e6 / median(mine.map(r => r.seconds)), 1),
          engineCPU: med('engineCPU'), webProcessCPU: med('webProcessCPU'), uiProcessCPU: med('uiProcessCPU'),
          relayCPU: med('relayCPU'), channelCPU: med('channelCPU'),
        }
      }
    } finally {
      await browser?.close()
    }
  }
} finally {
  replay.stop()
  xvfb?.kill()
}

const result = {
  sample: { file: path.basename(SAMPLE), updates: meta.updates, MB: round(meta.bytes / 1e6), recorded: meta.recorded, xvnc: meta.xvnc },
  machine: { cpus: os.cpus().length, model: os.cpus()[0]?.model },
  repeat: REPEAT, summary, runs,
}
console.log(JSON.stringify(summary, null, 2))
if (OUT) {
  await mkdir(path.dirname(OUT), { recursive: true })
  await writeFile(OUT, JSON.stringify(result, null, 2))
}
