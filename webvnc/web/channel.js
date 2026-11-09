// A WebSocket-shaped object for noVNC whose bytes travel through the app instead of a socket.
//
// noVNC's RFB accepts "a WebSocket or RTCDataChannel" in place of a URL and only checks that the
// object has send / close / binaryType / onopen / onmessage / onerror / protocol / readyState. With
// this object the page opens no connection at all: the app holds the real WebSocket to the display
// bridge (with the Access headers), posts what arrives here with receive(), and gets what noVNC
// sends as {type: 'send'} messages. There is no local port another process could connect to.

import { post, toBase64, fromBase64 } from './host.js'

const CONNECTING = 0
const OPEN = 1
const CLOSING = 2
const CLOSED = 3

export class HostChannel {
  constructor() {
    // own properties, so noVNC's Object.keys check finds them
    this.binaryType = 'arraybuffer'
    this.protocol = ''
    this.readyState = CONNECTING
    this.onopen = null
    this.onmessage = null
    this.onclose = null
    this.onerror = null
    this.bytesIn = 0
    this.bytesOut = 0
    this._closeListeners = []
  }

  send(data) {
    if (this.readyState !== OPEN) {
      return
    }
    // noVNC hands over a view into its own send queue and reuses it: encode now, not later.
    const bytes = data instanceof Uint8Array ? data : new Uint8Array(data)
    this.bytesOut += bytes.length
    post({ type: 'send', data: toBase64(bytes) })
  }

  // close() without a code is what noVNC's disconnect() does; like a browser WebSocket closing
  // without a status, the app then drops the link without a clean close, so the bridge keeps a
  // held lease. close(1000) hands it back.
  close(code, reason) {
    if (this.readyState === CLOSING || this.readyState === CLOSED) {
      return
    }
    this.readyState = CLOSING
    post({ type: 'close', code: code ?? null, reason: reason ?? '' })
  }

  addEventListener(type, listener) {
    if (type === 'close') {
      this._closeListeners.push(listener)
    }
  }

  removeEventListener(type, listener) {
    this._closeListeners = this._closeListeners.filter(l => l !== listener)
  }

  // ---- called by the app (through window.shionVNC) ----

  hostOpened() {
    if (this.readyState !== CONNECTING) {
      return
    }
    this.readyState = OPEN
    this.onopen?.({ type: 'open' })
  }

  // One base64 string per WebSocket message from the bridge, in order. The app batches what arrived
  // while the page was busy into one call, but keeps the messages apart: noVNC reads the bytes of
  // one message event, and after its handshake it waits for the next event before reading on.
  hostReceived(messages) {
    if (this.readyState !== OPEN) {
      return
    }
    for (const base64 of Array.isArray(messages) ? messages : [messages]) {
      const bytes = fromBase64(base64)
      this.bytesIn += bytes.length
      this.onmessage?.({ type: 'message', data: bytes.buffer })
    }
  }

  hostClosed(code, reason) {
    if (this.readyState === CLOSED) {
      return
    }
    this.readyState = CLOSED
    const event = { type: 'close', code: code ?? 1006, reason: reason ?? '', wasClean: code != null && code !== 1006 }
    for (const listener of this._closeListeners) {
      listener(event)
    }
    this.onclose?.(event)
  }
}
