// The app's side of HostChannel (option C), in Node for the Chromium tests: it holds the real
// WebSocket to the display bridge (with the Access headers) and moves bytes to and from the page.
// The Swift shell does the same with Network.framework and WKWebView (macos/…/ChannelHost.swift).
//
// Server→page: what arrives while the previous hand-over is still in flight goes over in one
// evaluate (like callAsyncJavaScript), as a list with one base64 string per bridge message.

export function createChannelHost({ upstream, headers }) {
  let ws = null
  let viewer = null
  let queue = []
  let flushing = false
  const stats = { batches: 0, bytesDown: 0, bytesUp: 0, closeCode: null, sentClose: null }

  async function flush() {
    if (flushing || !viewer) return
    flushing = true
    try {
      while (queue.length) {
        const batch = queue.map(b => b.toString('base64'))   // one string per bridge message
        queue = []
        stats.batches += 1
        await viewer.page.evaluate(list => window.shionVNC.channelReceived(list), batch)
      }
    } catch {
      // page gone
    } finally {
      flushing = false
    }
  }

  return {
    stats,
    // what the page posts (passed to openViewer as channelHost)
    onPageMessage(message) {
      if (message.type === 'send') {
        if (ws?.readyState === WebSocket.OPEN) {
          const bytes = Buffer.from(message.data, 'base64')
          stats.bytesUp += bytes.length
          ws.send(bytes)
        }
      } else if (message.type === 'close') {
        // 1000 / 1001 close cleanly (the bridge hands the lease back); anything else closes without
        // a status, which the bridge treats like a dropped link.
        const clean = message.code === 1000 || message.code === 1001
        stats.sentClose = clean ? message.code : 'no status'
        if (ws && ws.readyState <= WebSocket.OPEN) clean ? ws.close(message.code) : ws.close()
      }
    },
    start(v) {
      viewer = v
      ws = new WebSocket(upstream, { headers })
      ws.binaryType = 'arraybuffer'
      ws.onopen = () => { viewer.page.evaluate(() => window.shionVNC.channelOpened()).catch(() => {}) }
      ws.onmessage = event => {
        const bytes = Buffer.from(event.data)
        stats.bytesDown += bytes.length
        queue.push(bytes)
        setImmediate(flush)
      }
      ws.onclose = async event => {
        stats.closeCode = event.code
        while (flushing || queue.length) {
          await flush()
          await new Promise(resolve => setTimeout(resolve, 5))
        }
        viewer.page.evaluate(([c, r]) => window.shionVNC.channelClosed(c, r), [event.code, event.reason]).catch(() => {})
      }
      ws.onerror = () => {}
    },
    stop() {
      try { ws?.close() } catch { /* closed */ }
    },
  }
}
