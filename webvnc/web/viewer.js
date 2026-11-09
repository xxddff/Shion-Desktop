// The cloud-desktop page: noVNC 1.7.0 (unmodified, web/vendor/novnc) plus the few things the app
// needs around it. The app drives it through window.shionVNC and hears back through host.js.
//
// What the page knows: how to reach the bytes (a ws://127.0.0.1 relay URL with a one-time
// subprotocol token, or the app itself through HostChannel). What it never knows: the gateway's
// address, the display ticket, the Access service token, the viewer id.
//
// Additions to stock noVNC, all from outside its files:
// - input method: keys go to a hidden <textarea> placed where you last clicked, not to noVNC's
//   canvas. Composed text (Chinese, Japanese, emoji picker…) is sent as clipboard + Ctrl+V, never
//   as one Unicode keysym per character; ordinary keys go through noVNC's own Keyboard class.
// - ⌘ as Ctrl on a Mac (stock noVNC sends ⌘ as Alt), except the shortcuts that stay with the Mac.
// - ⌘V / paste: the pasted text goes the same clipboard + Ctrl+V way.
// - the mouse's back / forward buttons are not passed on (see README: Hermes' RFB filter frames a
//   PointerEvent as 6 bytes, noVNC sends 7 for those buttons once Xvnc offers ExtendedMouseButtons).
// - the close code of the display bridge (4000 control taken, 4401 ticket, 4001 desktop gone) is
//   reported, which noVNC's own disconnect event leaves out.

import RFB from './vendor/novnc/core/rfb.js'
import Keyboard from './vendor/novnc/core/input/keyboard.js'
import KeyTable from './vendor/novnc/core/input/keysym.js'
import { getKeysym } from './vendor/novnc/core/input/util.js'
import { HostChannel } from './channel.js'
import { post } from './host.js'

const screenEl = document.getElementById('screen')
const ime = document.getElementById('ime')
const isMac = /^Mac/.test(navigator.platform) || /^iP(hone|ad|od)/.test(navigator.platform)

// The bridge closes the display socket on any ClientCutText over 256 KiB (rfb_filter.py,
// -MaxCutText). noVNC sends the text as CRLF + NUL, deflated; keep a margin for the framing.
const MAX_PASTE_BYTES = 256 * 1024 - 4096
// ⌘ shortcuts that stay with the Mac (the app routes them before the page sees them; this list is
// the page's own guard). Everything else with ⌘ goes to the remote as Ctrl.
const DEFAULT_APP_KEYS = ['KeyQ', 'KeyH', 'KeyM', 'Comma', 'Tab', 'Backquote', 'Space']

let rfb = null
let lastClient = null   // the picture stays readable after a close (tests)
let sock = null
let channel = null
let state = 'idle'
let viewOnly = true
let appKeys = new Set(DEFAULT_APP_KEYS)
let closeCode = 0
let closeReason = ''
let stats = newStats()
let lastCommit = { text: '', at: 0 }
// Tests only (connect({debugKeys: true})): the keysyms the page sent, so a test can see what a
// shortcut became. Off in the app: it would hold whatever was typed.
let keyLog = null

function newStats() {
  return { t0: performance.now(), connectedMs: null, firstFrameMs: null, updates: 0, bytesIn: 0, bytesOut: 0 }
}

function elapsed() {
  return Math.round(performance.now() - stats.t0)
}

// ---------------------------------------------------------------- connection

function connect(options = {}) {
  teardown()
  stats = newStats()
  closeCode = 0
  closeReason = ''
  viewOnly = options.viewOnly !== false
  appKeys = new Set(options.appKeys ?? DEFAULT_APP_KEYS)
  keyLog = options.debugKeys ? [] : null

  if (options.transport === 'channel') {
    channel = new HostChannel()
    sock = channel
  } else {
    // The token rides in the subprotocol: Network.framework's WebSocket server shows the app the
    // offered subprotocols and headers but not the request path.
    sock = new WebSocket(options.url, options.protocols ?? [])
    sock.binaryType = 'arraybuffer'
    sock.addEventListener('message', event => { stats.bytesIn += event.data.byteLength })
  }
  // Before RFB takes the socket: the bridge's verdict is in the close frame, and noVNC's
  // disconnect event only says {clean}.
  sock.addEventListener('close', event => {
    closeCode = event.code
    closeReason = event.reason
  })

  const client = new RFB(screenEl, sock, { shared: true })
  client.scaleViewport = true
  client.resizeSession = false       // never SetDesktopSize: it would resize the agent's screen
  client.focusOnClick = false        // the IME textarea takes the focus, not noVNC's canvas
  client.background = '#000'
  client.qualityLevel = options.qualityLevel ?? 7   // what the official desktop app uses
  client.compressionLevel = options.compressionLevel ?? 2
  client.viewOnly = viewOnly
  client.showDotCursor = viewOnly

  // Measurements only: ask for a different encoding list (e.g. ZRLE like the native client), to
  // tell the encoding's share from the client's. Not used by the app.
  if (Array.isArray(options.encodings)) {
    client._sendEncodings = function () {
      RFB.messages.clientEncodings(this._sock, options.encodings)
    }
  }

  // Frame counting for the measurements: noVNC has no public "frame" event. _framebufferUpdate()
  // returns true once a whole FramebufferUpdate message has been decoded.
  const decode = client._framebufferUpdate
  client._framebufferUpdate = function () {
    const done = decode.call(this)
    if (done) {
      stats.updates += 1
      if (stats.firstFrameMs === null) {
        stats.firstFrameMs = elapsed()
        post({ type: 'firstFrame', ms: stats.firstFrameMs })
      }
    }
    return done
  }

  client.addEventListener('connect', () => {
    if (rfb !== client) return
    state = 'connected'
    stats.connectedMs = elapsed()
    post({ type: 'state', state, ms: stats.connectedMs })
  })
  client.addEventListener('disconnect', event => {
    if (rfb !== client) return
    state = 'disconnected'
    rfb = null
    post({ type: 'state', state, code: closeCode, reason: closeReason, clean: !!event.detail?.clean, ms: elapsed() })
  })
  client.addEventListener('desktopname', event => post({ type: 'desktopName', name: event.detail.name }))
  client.addEventListener('securityfailure', event => post({ type: 'securityFailure', status: event.detail.status }))

  rfb = client
  lastClient = client
  state = 'connecting'
  return true
}

// handBack: close with 1000 first, which is what makes the bridge give the lease back. noVNC's
// own disconnect() closes without a status code, which the bridge treats as a dropped link.
function disconnect(handBack = false) {
  if (handBack && sock) {
    sock.close(1000)
  }
  rfb?.disconnect()
}

function teardown() {
  if (rfb) {
    const client = rfb
    rfb = null
    try { client.disconnect() } catch { /* already closed */ }
  }
  sock = null
  channel = null
  state = 'idle'
}

function setViewOnly(value) {
  viewOnly = !!value
  if (rfb) {
    rfb.viewOnly = viewOnly
    rfb.showDotCursor = viewOnly
  }
  if (viewOnly) {
    ime.blur()
    endComposition()
  }
}

// ---------------------------------------------------------------- typing and pasting

function extendedClipboard() {
  // set from the server's capabilities when the connection starts (Xvnc: text, notify / request)
  return !!(rfb?._clipboardServerCapabilitiesFormats?.[1] && rfb?._clipboardServerCapabilitiesActions?.[1 << 27])
}

// Puts text on the remote clipboard and presses Ctrl+V there: Xvnc then asks for the text and
// noVNC hands it over. This is the way composed text and pastes reach the remote.
function typeText(text) {
  if (!rfb || state !== 'connected') return { ok: false, reason: 'not-connected' }
  if (viewOnly) return { ok: false, reason: 'view-only' }
  if (!text) return { ok: false, reason: 'empty' }
  const size = new TextEncoder().encode(text.replace(/\r\n|\r|\n/g, '\r\n')).length + 1
  if (size > MAX_PASTE_BYTES) return { ok: false, reason: 'too-large' }
  if (!extendedClipboard() && /[^\x00-\xff]/.test(text)) {
    return { ok: false, reason: 'no-extended-clipboard' }   // noVNC would turn it into "?"
  }
  rfb.clipboardPasteFrom(text)
  pressWithControl(KeyTable.XK_v, 'KeyV')
  return { ok: true, bytes: size }
}

function sendKey(keysym, code, down) {
  if (!rfb || viewOnly) return
  if (keyLog) {
    keyLog.push(`${down ? '+' : '-'}${(keysym ?? 0).toString(16)}`)
    if (keyLog.length > 64) keyLog.shift()
  }
  rfb.sendKey(keysym, code, down)
}

function pressWithControl(keysym, code, shift = false) {
  sendKey(KeyTable.XK_Control_L, 'ControlLeft', true)
  if (shift) sendKey(KeyTable.XK_Shift_L, 'ShiftLeft', true)
  sendKey(keysym, code, true)
  sendKey(keysym, code, false)
  if (shift) sendKey(KeyTable.XK_Shift_L, 'ShiftLeft', false)
  sendKey(KeyTable.XK_Control_L, 'ControlLeft', false)
}

function commit(text) {
  if (!text) return
  lastCommit = { text, at: performance.now() }
  const result = typeText(text)
  post({ type: 'typed', ok: result.ok, reason: result.reason ?? null, chars: [...text].length })
}

function endComposition() {
  ime.classList.remove('composing')
  ime.value = ''
}

// Keys reach the remote through noVNC's own Keyboard class, attached to the textarea instead of
// the canvas. This listener runs first and keeps from it what is not a plain key press.
function keyGate(event) {
  if (viewOnly || !rfb) {
    event.stopImmediatePropagation()
    return
  }
  if (event.isComposing || event.keyCode === 229) {
    event.stopImmediatePropagation()   // the input method has this key
    return
  }
  if (isMac && (event.metaKey || event.key === 'Meta')) {
    event.stopImmediatePropagation()
    commandKey(event)
  }
}

function commandKey(event) {
  if (event.key === 'Meta' || event.type === 'keyup') {
    event.preventDefault()             // ⌘ itself never reaches the remote
    return
  }
  if (event.code === 'KeyV') {
    return                             // the paste event brings the text (default action kept)
  }
  if (appKeys.has(event.code)) {
    return                             // the Mac's
  }
  event.preventDefault()
  const keysym = getKeysym(event)
  if (keysym) {
    pressWithControl(keysym, event.code, event.shiftKey)
  }
}

ime.addEventListener('keydown', keyGate, true)
ime.addEventListener('keyup', keyGate, true)
const keyboard = new Keyboard(ime)
keyboard.onkeyevent = (keysym, code, down) => sendKey(keysym, code, down)
keyboard.grab()

ime.addEventListener('compositionstart', () => ime.classList.add('composing'))
ime.addEventListener('compositionend', event => {
  commit(event.data)
  endComposition()
})
// Text inserted without a composition: punctuation some input methods commit directly, the
// emoji & symbols picker, press-and-hold accents.
ime.addEventListener('input', event => {
  if (event.isComposing) return
  const duplicate = event.data === lastCommit.text && performance.now() - lastCommit.at < 100
  if (!duplicate && event.inputType !== 'insertFromComposition' && event.data) {
    commit(event.data)
  }
  if (!ime.classList.contains('composing')) ime.value = ''
})
ime.addEventListener('paste', event => {
  event.preventDefault()
  commit(event.clipboardData?.getData('text/plain') ?? '')
})

// ---------------------------------------------------------------- mouse

function placeIme(event) {
  const box = screenEl.getBoundingClientRect()
  ime.style.left = `${Math.round(event.clientX - box.left)}px`
  ime.style.top = `${Math.round(event.clientY - box.top)}px`
}

function blockSideButtons(event) {
  if (event.button === 3 || event.button === 4 || (event.buttons & 0x18)) {
    event.stopPropagation()
    event.preventDefault()
    return true
  }
  return false
}

screenEl.addEventListener('mousedown', event => {
  if (blockSideButtons(event)) return
  if (viewOnly) {
    // noVNC drops it (view-only); the app decides whether this click takes over. The click that
    // takes over is never sent to the remote.
    post({ type: 'pointer', button: event.button })
    return
  }
  placeIme(event)
  setTimeout(() => ime.focus({ preventScroll: true }), 0)
}, true)
screenEl.addEventListener('mouseup', blockSideButtons, true)
screenEl.addEventListener('mousemove', blockSideButtons, true)

// ---------------------------------------------------------------- the app's handle

function report() {
  return {
    state,
    viewOnly,
    closeCode,
    closeReason,
    ...stats,
    bytesIn: channel ? channel.bytesIn : stats.bytesIn,
    bytesOut: channel ? channel.bytesOut : stats.bytesOut,
    extendedClipboard: extendedClipboard(),
    qemuKeys: !!rfb?._qemuExtKeyEventSupported,
    extendedMouseButtons: !!rfb?._extendedPointerEventSupported,
    cursor: rfb?._canvas ? getComputedStyle(rfb._canvas).cursor.slice(0, 16) : null,
    keys: keyLog ? [...keyLog] : undefined,
  }
}

// Pixels for the tests: an FNV-1a hash of the RGB bytes of the decoded picture.
function pictureHash() {
  const client = rfb ?? lastClient
  if (!client) return null
  const image = client.getImageData()
  let h = 0x811c9dc5
  const d = image.data
  for (let i = 0; i < d.length; i += 4) {
    for (let j = 0; j < 3; j++) {
      h ^= d[i + j]
      h = Math.imul(h, 0x01000193) >>> 0
    }
  }
  return { width: image.width, height: image.height, fnv1a: h.toString(16).padStart(8, '0') }
}

function picturePNG() {
  const client = rfb ?? lastClient
  return client ? client.toDataURL('image/png') : null
}

window.shionVNC = Object.freeze({
  connect,
  disconnect,
  setViewOnly,
  typeText,
  report,
  pictureHash,
  picturePNG,
  channelOpened: () => channel?.hostOpened(),
  channelReceived: messages => channel?.hostReceived(messages),
  channelClosed: (code, reason) => channel?.hostClosed(code, reason),
})

post({
  type: 'ready',
  secureContext: window.isSecureContext,
  subtleCrypto: !!globalThis.crypto?.subtle,
  nativeBase64: typeof Uint8Array.fromBase64 === 'function',
  origin: location.origin,
})
