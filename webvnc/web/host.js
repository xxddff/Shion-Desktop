// The page's only way out to the app: one script message handler named "shion" (WKWebView and
// WebKitGTK expose it as window.webkit.messageHandlers.shion), or the test binding the Chromium
// harness installs. Messages are plain objects; nothing secret ever goes this way, because the page
// never sees the ticket, the Access headers or the gateway's address.

export function post(message) {
  const handler = globalThis.webkit?.messageHandlers?.shion
  if (handler) {
    handler.postMessage(message)
  } else if (typeof globalThis.shionTestHost === 'function') {
    globalThis.shionTestHost(message)
  }
}

// Base64 both ways (the host bridge only carries strings). Uint8Array.fromBase64 / toBase64 are in
// Safari 18.2+, Chrome 140+ and current WebKitGTK; the fallbacks are for anything older.
export function toBase64(bytes) {
  if (typeof bytes.toBase64 === 'function') {
    return bytes.toBase64()
  }
  let s = ''
  for (let i = 0; i < bytes.length; i += 0x8000) {
    s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000))
  }
  return btoa(s)
}

export function fromBase64(text) {
  if (typeof Uint8Array.fromBase64 === 'function') {
    return Uint8Array.fromBase64(text)
  }
  const s = atob(text)
  const out = new Uint8Array(s.length)
  for (let i = 0; i < s.length; i++) {
    out[i] = s.charCodeAt(i)
  }
  return out
}
