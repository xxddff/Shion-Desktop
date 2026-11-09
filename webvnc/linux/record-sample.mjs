// Records what Xvnc (through the testbed bridge) sends noVNC 1.7.0, message by message, for the
// macOS shell to replay with linux/replay_messages.py (no Xvnc on macOS). The replay ignores what
// the client sends, so it only fits a client that asks for the same things: this noVNC page with
// the same settings.
//
//   node webvnc/linux/record-sample.mjs static OUTDIR   static scene, 3 s; also the picture noVNC
//                                                        decoded (NAME.expected.png) and its hash
//   node webvnc/linux/record-sample.mjs scroll OUTDIR   a remote Chrome scrolling the article, ~3 s
//
// Writes OUTDIR/novnc-NAME.messages.z (see replay_messages.py) and novnc-NAME.json.

import { writeFile, mkdir } from 'node:fs/promises'
import path from 'node:path'
import { ROOT, startTestbed, startRelay, launchChromium, openViewer, remoteChrome, windowTitle, until, sleep } from './lib.mjs'

const [kind = 'static', out = path.join(ROOT, 'testdata')] = process.argv.slice(2)
await mkdir(out, { recursive: true })
const file = path.join(out, `novnc-${kind}.messages.z`)

const tb = await startTestbed({ display: ':45', port: 8795, scene: 'static', name: `rec-${kind}` })
const browser = await launchChromium()
let chrome = null
try {
  if (kind === 'scroll') {
    chrome = await remoteChrome(tb, `file://${path.join(ROOT, 'linux', 'scenes', 'article.html')}`, { width: 1440, height: 900, name: 'article' })
    await until(async () => (await windowTitle(tb, '^article ready')) !== null, { timeout: 30000, what: 'the article' })
    await sleep(1500)
  } else {
    await sleep(1500)   // let the static windows draw
  }
  const { url } = await tb.observe('recorder')
  const relay = await startRelay({ upstream: url, record: file })
  const viewer = await openViewer(browser)
  await viewer.call('connect', { transport: 'relay', url: relay.url, protocols: [relay.protocol], viewOnly: true })
  await viewer.waitFor(m => m.type === 'firstFrame', { timeout: 15000 })
  if (kind === 'scroll') {
    await tb.x('xdotool', ['mousemove', '700', '450', 'click', '--repeat', '30', '--delay', '100', '5'], { timeout: 10000 })
    await sleep(1000)
  } else {
    await sleep(3000)   // includes Xvnc's lossless refresh after the JPEG parts
  }
  const report = await viewer.report()
  const picture = await viewer.call('pictureHash')
  const png = await viewer.call('picturePNG')
  await viewer.call('disconnect', true)
  const r = await relay.result
  const meta = { kind, novnc: '1.7.0', xvnc: 'TigerVNC 1.13.1', updates: report.updates, bytes: r.recorded, picture,
    recorded: new Date().toISOString() }
  await writeFile(path.join(out, `novnc-${kind}.json`), JSON.stringify(meta, null, 2) + '\n')
  if (kind === 'static') {
    await writeFile(path.join(out, `novnc-${kind}.expected.png`), Buffer.from(png.split(',')[1], 'base64'))
  }
  console.log(JSON.stringify(meta))
} finally {
  await chrome?.stop()
  await browser.close()
  await tb.stop()
}
