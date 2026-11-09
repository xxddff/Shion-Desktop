# 网页查看器（noVNC）：探路

云桌面的画面除了自己写的原生客户端（`rfb/`），另一条路是把 noVNC 这个现成的网页 VNC 客户端嵌进 App 的 WebView。这里是对这条路的探路：用 Hermes 官方桌面端用的同一个 noVNC，做了一个能跑的页面、两种接入 Cloudflare Access 的办法、Linux 上的端到端测试和测量，以及一个 macOS 的最小外壳。结论照实写，两边的长处短处都列出来。

这不是 App 的一部分：`macos/`、`rfb/`、`prototype/` 都没动。

## 结论

- **能用。** noVNC 1.7.0 在 WebView 里经过 Hermes 自己的 RFB 过滤器连上 Xvnc：只看、接管、交还、被挤掉（4000）、ticket 用过（4401）、断网保留租约、中文日文 emoji 输入，在 Linux 的 Chrome 里 20 项全过，在 WebKitGTK 里 5 项全过。macOS 27 的 WKWebView（CI 上，对着回放的录像）11 项过了 9 项：页面从 App 自己的 scheme 加载、画面和 Chrome 解出来的逐像素对得上、1000 交还、中转拒绝别的本机连接、⌘A→Ctrl+A、⌘Q 留给菜单、⌘V 粘贴。没过的两项都是 4000：App 一侧用 Network.framework 开的 WebSocket 收不到服务器先发的关闭帧。毛病在 App 一侧的传输，不在网页；原生 `rfb/` 碰到的是同一个问题，已经改用 URLSession（「发现」第 11 条）。
- **认证：推荐「丙」，不在本机开端口。** 页面拿到的是一个「长得像 WebSocket」的对象，真的 WebSocket 由 App 开，带 Access 的两个头（App 里直接用原生的 `URLSessionWebSocketTransport`）。ticket、service token、网关地址都不进网页，也没有别的进程能连的端口。代价是字节要经 WebKit 的脚本桥转一道（base64），在 Mac 上实测几乎不花钱：解同一段录像，丙只比甲慢 8%，App 进程的 CPU 一样。「甲」（本机中转）也做好、测过，安全上靠一次性令牌、Origin 检查、只接一条连接；「乙」（在 WebView 里登录 Access 拿 cookie）不推荐。
- **性能：各有输赢，差别主要来自编码，不来自客户端。** noVNC 和 Xvnc 谈的是 Tight + JPEG，原生现在只有 ZRLE。Chrome 滚动 5 秒：noVNC 收到 262 帧、33.6 MB，原生 81 帧、42.8 MB；Xvnc 编码用的 CPU，Tight 1.4 秒，ZRLE 4.0 秒。让 noVNC 也只用 ZRLE，就只有 74 帧，和原生一样。但同样的帧，原生解码省得多：ZRLE 每帧原生约 13 毫秒，noVNC 约 52 毫秒（Linux 无头 Chrome，软件绘制）。Mac 上的 WebKit 解得不慢：一段 17.8 MB 的 Tight+JPEG 滚动录像，WKWebView 1.0 秒解完，WebContent 进程用了 1.1 秒 CPU（同一段录像，Linux 的无头 Chrome 1.5 秒，WebKitGTK 2.8 秒；机器不同）。首帧：150 毫秒往返时原生 308 毫秒，noVNC 708 毫秒（原生把握手一次发完，noVNC 一来一回）。
- **安全：网页多一层沙盒，原生少一大块代码。** 网页的解码（JS 的 inflate、ZRLE、Tight，WebKit 的 JPEG）在 WebContent 进程里，那个进程有沙盒，碰不到钥匙串和文件。Shion 因为要用辅助功能不开沙盒，所以原生解码出了问题就是整个 App 的权限。反过来，网页带进来一整个浏览器引擎，原生是自己写的、有边界检查的 Swift。服务器是自己的 VPS，两边都够用；这一条不是决定因素。
- **功能：输入法、⌘ 当 Ctrl、粘贴，在网页里也得自己写，已经写好。** noVNC 本身不支持输入法拼写，在 Mac 上把 ⌘ 当 Alt 发。这里的页面加了一层：键盘进一个放在点击位置的隐藏文本框，拼好的字走「剪贴板 + Ctrl+V」，和原生的打算一样。
- **建议：原生为主，网页当过渡和备用。** 详见「建议」。

## 目录

```
webvnc/
├ web/                 网页（App 打包进去的就是这些）
│ ├ viewer.html/.css    页面：严格的 CSP，一个画面，一个输入法文本框
│ ├ viewer.js           接 noVNC：连接、关闭码、只看/接管、输入法、⌘→Ctrl、粘贴、侧键
│ ├ channel.js          HostChannel：给 noVNC 的「WebSocket」，字节走 App（丙）
│ ├ host.js             页面唯一的出口：window.webkit.messageHandlers.shion
│ ├ fetch-novnc.sh      取 noVNC 1.7.0：npm 包，按 integrity 校验，原样解开（--check 核对）
│ └ vendor/             noVNC（不提交，脚本取）
├ relay/relay.py        甲：本机中转（Linux 测试用；macOS 版在 macos/）
├ linux/                Linux 上的测试和测量
│ ├ e2e.mjs             无头 Chrome 端到端（20 项）
│ ├ webkit.mjs          WebKitGTK（webkitgtk_host.py）
│ ├ measure.mjs         和 rfb-probe 比
│ ├ decode.mjs          解码吞吐：一段录像，Chrome 和 WebKitGTK，甲和丙
│ ├ record-sample.mjs   录 noVNC 会话，给 macOS 回放
│ ├ replay_messages.py  按原来的消息边界回放
│ ├ channel-host.mjs    丙的 App 一侧（Node 版）
│ ├ filter_check.py     Hermes 的过滤器和 noVNC 的侧键消息
│ ├ relay_probe.py      冒充别的本机进程去连中转
│ └ scenes/article.html 测量时远端 Chrome 滚动的页面
├ macos/                最小外壳：AppKit + WKWebView + 中转 + 通道 + 自检
├ testdata/             一段录好的 noVNC 会话（静止画面）和它解出来的图
└ results/              测得的原始数据（JSON）：Linux 的测量、端到端、WebKitGTK、解码吞吐，macOS 的自检
```

## 官方桌面端怎么用 noVNC

依据 Hermes `apps/desktop/src/plugins/hermes-bots/screen-pane.tsx`、`screen-connection.ts`，`hermes_cli/web_routers/display.py`，`tui_gateway/methods_display.py`（commit `9dcf7714`，2026-11-09）。官方的网页 Dashboard 没有画面面板，只有桌面端（Electron）有。

| 方面 | 官方的做法 |
| --- | --- |
| 版本 | `@novnc/novnc` 1.7.0，钉死版本，动态 import |
| 拿 ticket | 在这个助手的 gateway 连接上调 `display.observe`，带 `profile`；重连时带上这个窗口自己发到的 `viewer_id`。WebSocket 地址是同一个网关的 `/api/display/ws?display_ticket=…`，去掉 gateway 的登录凭证（桥只认 ticket） |
| 连接 | 自己 `new WebSocket(url)`，`binaryType = 'arraybuffer'`，先挂一个 `close` 监听记下关闭码，再交给 `new RFB(target, ws, { shared: true })`。原因写在注释里：noVNC 1.7 的 `disconnect` 事件只有 `{clean}`，没有关闭码 |
| 设置 | `scaleViewport = true`（按面板缩放）、`resizeSession = false`（不发 SetDesktopSize）、`focusOnClick = true`、`background = 'transparent'`、`qualityLevel = 7`、`viewOnly = !持有租约`（只是界面，闸门在桥） |
| 租约 | `display.lease.acquire` / `release` 带 `viewer_id`；广播里只有 `viewer_hash`（`viewer_id` 的 SHA-256 前 12 位），用它认自己；有「强制交还」，给刷新后 id 变了的窗口用 |
| 4000 | 回到只看，换新 ticket 重连，顶上一行提示；拨号后 10 秒内又被挤掉，连续超过 3 次就停下，显示错误和「重新连接」 |
| 交还 | 关面板时先 `socket.close(1000)` 再 `rfb.disconnect()`：noVNC 自己关是不带状态码的，桥会当成断网、不交还 |
| 剪贴板 | 只认用户真的粘贴：画面上的 `paste` 事件 → `clipboardPasteFrom(text)`（只看时、超过 256 KiB 时不发）。不发 Ctrl+V。按代码看，Mac 上按 ⌘V 时文字进了远端剪贴板，按键却照 noVNC 的映射发成 Alt+V，远端程序不会粘贴，还得再按一次 Ctrl+V（读代码的结论，没在官方 App 上试） |
| 键盘、输入法 | 没有额外处理，就是 noVNC 的：Mac 上 ⌘ 发成 Alt、⌥ 发成 Mode_switch；没有输入法拼写支持（见下面「功能」）。用 `data-terminal`、`data-remote-screen` 让 App 的快捷键别抢画面的按键 |
| 光标 | noVNC 默认：总是请求 Cursor 伪编码，本地画光标 |
| 缩放 | `scaleViewport`，按面板等比缩放；不改远端分辨率 |
| 编码 | noVNC 默认顺序：CopyRect、（浏览器能用 WebCodecs 时 H.264）、Tight、TightPNG、ZRLE、JPEG、Hextile、RRE、Zlib、Raw；画质 7、压缩 2。Xvnc 用 Tight，照片一样的区域用 JPEG，画面停下后再无损补一遍 |
| 安全上下文 | 要 `crypto.subtle`（算 `viewer_hash`），走纯 HTTP 访问时直接显示「需要 HTTPS」 |

## 在 App 里怎么嵌

### WKWebView 还是 SwiftUI 的 WebView / WebPage

用 `NSViewRepresentable` 包一个 `WKWebView` 的子类。要害是键盘：子类可以重写 `performKeyEquivalent(with:)`，让 ⌘Q、⌘H、⌘M、⌘,、⌘Tab 直接回到 App 的菜单，页面永远看不到；其余 ⌘ 组合先给页面（页面把 ⌘ 换成 Ctrl 发给远端），页面不要的再回菜单。SwiftUI 的 `WebView` / `WebPage`（macOS 26 起）没法插进这一步。`WebPage` 的 URL scheme handler 和 `callJavaScript` 也能用，所以别的网页内容可以用它，画面用 WKWebView。

### 加载：打包，用 URL scheme handler

- noVNC 打包进 App，`WKURLSchemeHandler` 在 `shion-webvnc://app/` 下提供 `web/` 里的文件。页面里 noVNC 是 ES 模块，同源 import。
- `loadFileURL` 不行：macOS 27 的 WKWebView 用它打开同一个页面，8 秒内页面没发出 `ready`，ES 模块或者 CSP 的 `'self'` 在 file:// 下不工作（没再细分是哪一个）。Chrome 本来就不让 file:// 加载模块。所以用 scheme handler。
- noVNC 原样使用，不改它的文件。`fetch-novnc.sh` 从 npm 取 1.7.0 的包，先按 registry 给的 sha512 校验再解开，只留 `core/`、`vendor/pako` 和许可证；`--check` 核对磁盘上的文件和包里的一字不差。正式接进 App 时，可以把这些文件提交进仓库，或者在 Xcode 的构建阶段跑这个脚本。

### CSP

页面自己带一条（meta），App 再在响应头里加一条更严的（两条都生效）：

```
default-src 'none'; script-src 'self'; style-src 'self'; img-src data:;
connect-src ws://127.0.0.1:<端口>      # 甲
connect-src 'none'                      # 丙：页面不需要任何网络
```

noVNC 1.7 需要 `img-src data:`：Tight 的 JPEG 块是用 `data:` 图片解的，光标也是 `data:` 图片。它不用 eval、不插 `<style>`、不用 Worker。测过：内联脚本不执行，`fetch` 外网被拦（Chrome、WebKitGTK、macOS 27 的 WKWebView）。

### JS ↔ Swift：只留最小的桥

| 方向 | 消息 | 说明 |
| --- | --- | --- |
| App → 页面 | `connect({transport, url, protocols, viewOnly})` | `transport`: `relay`（甲）或 `channel`（丙）。地址只有 `ws://127.0.0.1:端口/`，不带 ticket |
| | `setViewOnly(bool)` | 租约变了 |
| | `disconnect(handBack)` | `true` 时先用 1000 关（桥交还租约） |
| | `typeText(text)` | ⌘V、输入法确认的文字：剪贴板 + Ctrl+V |
| | `channelOpened / channelReceived(list) / channelClosed(code, reason)` | 丙：桥发来的消息，每条一个 base64 字符串 |
| 页面 → App | `ready` | 页面载入了（顺带报：安全上下文、Origin） |
| | `state` | `connected` / `disconnected`（带桥的关闭码：4000、4401、4001、1000…） |
| | `pointer` | 只看时点了画面：App 决定要不要接管；这一下点击不会发给远端 |
| | `typed` | 一次粘贴发出去没有（只有结果和字数，不带内容） |
| | `send` / `close` | 丙：noVNC 要发的字节、要关连接 |

没有经过这座桥的秘密：ticket、`viewer_id`、service token、网关地址都只在 App 里。

### 键盘、焦点、输入法

- **键盘进一个隐藏文本框，不进 noVNC 的画布。** 接管时点画面，页面把一个透明的 `<textarea>` 移到点的位置并聚焦（noVNC 的 `focusOnClick` 关掉）。普通按键交给 noVNC 自己的 `Keyboard` 类（换个绑定的元素，不改它的代码），所以键位映射还是 noVNC 的。
- **输入法。** 拼写中的按键（`isComposing` 或 keyCode 229）不发；拼写中的文字显示在点的位置，候选窗口跟着它；确认后的文字（`compositionend`），以及不经拼写直接插入的文字（表情与符号面板、一些标点、长按出的重音字母），都走「剪贴板 + Ctrl+V」。不逐字发 Unicode keysym。
- **⌘ 当 Ctrl。** Mac 上 ⌘A、⌘C、⌘L、⌘T 这类，发成 Ctrl+同一个键（noVNC 自己会发成 Alt）。⌘ 本身不发。⌘Q、⌘H、⌘M、⌘,、⌘Tab、⌘`、⌘空格留给 Mac：WKWebView 子类先拦一道，页面里也有同一张表。⌘V 不发按键，等 `paste` 事件把 Mac 剪贴板里的文字拿来，走「剪贴板 + Ctrl+V」。
- **鼠标侧键不发**（后退、前进键，见「发现」第 1 条）。
- **只看时显示一个小圆点光标。** noVNC 总是请求 Cursor 伪编码；只看时 Xvnc 把助手的指针画进画面、给我们一个空光标，不加圆点的话鼠标停在画面上就看不见了。
- 交还快捷键（比如 ⌃⌥）和「点画面外 3 秒内交还」都是 App 的事，和原生一样做。

## 认证：怎么过严格模式

网页里的 WebSocket 加不了请求头，而 Access 开着严格 service token 认证。三个办法：

### 甲：本机中转（`relay/relay.py`，macOS 版 `macos/…/Relay.swift`）

App 在 127.0.0.1 上开一个 WebSocket 服务，页面连它，它带上 Access 的头连真的画面桥，字节原样转发。

- 只监听回环地址的临时端口（`requiredInterfaceType = .loopback`、`acceptLocalOnly`，和 App 登录用的 LoopbackListener 一样）。
- **令牌放在子协议里**（`shion.<32 位十六进制>`，常数时间比较）：Network.framework 的 WebSocket 服务端只把请求的子协议和请求头交给 App，看不到路径，所以「随机路径」做不了。页面自己 `new WebSocket(url, ['shion.<令牌>'])` 再交给 noVNC（官方桌面端也是自己开 socket 再交给 noVNC）。
- **检查 Origin**：页面的 Origin 是 `shion-webvnc://app`（Chrome 测试里是 `https://webvnc.test`）；别的网页（比如浏览器里的恶意网页去扫本机端口）带的是它自己的 Origin，被拒。不带 Origin 的也拒（本机别的程序）。
- **只接一条连接**：第一条通过检查的连接一来就关掉监听。
- 关闭码两头传：桥的 4000、4401、4001、1003、1000 原样给页面；上游升级被拒（Access 或桥的 HTTP 403）给页面 4403；连不上给 4502。页面用 1000 / 1001 关，原样传给桥（交还租约）；页面不带状态码地关、或者 WebView 崩了，就不发关闭帧直接断上游（桥当成断网，租约留着）。
- 测过：没令牌、错令牌、对令牌但 Origin 不对、对令牌但没有 Origin，都是 403；页面连上之后，再来一个各项都对的连接，端口已经关了。macOS 的 `NWListener` 版也一样，只是被拒的连接直接断开（对方看到 ECONNABORTED），不回 HTTP 403。

### 乙：在 WebView 里登录 Access，用 cookie

页面带着 `CF_Authorization` cookie 连网关，就不需要 service token。没有做原型，原因：

- Access 要有一条 Allow 策略（README 的浏览器登录已经要求加了）。但 Shion 登录用的是 `ASWebAuthenticationSession`，而且 `prefersEphemeralWebBrowserSession = true`，cookie 不会留给 WebView。画面要自己再登录一次 Access（比如邮箱验证码），cookie 存在 WebView 的数据目录里。
- cookie 的寿命是这个应用（或策略）的会话时长，默认 24 小时，最长一个月。过期了，画面里会突然出现 Access 的登录页。
- WebSocket 要带上 cookie，页面最好和网关同源：用 `loadHTMLString(_:baseURL: https://网关/)` 加一个打包成单文件的 noVNC；否则是第三方 cookie，WebKit 默认会拦。
- ticket 要写进页面里的 WebSocket 地址；cookie 是整个 Access 应用的凭证，不只是画面的。
- 比甲、丙都弱，还多一个登录。

### 丙：HostChannel，页面里不开 socket（推荐）

noVNC 的 `RFB` 本来就接受「一个 WebSocket 或 RTCDataChannel」代替 URL，只检查对象上有没有 `send`、`close`、`binaryType`、`onopen`、`onmessage`、`onerror`、`protocol`、`readyState`。`channel.js` 就是这样一个对象：

- 页面 → App：`webkit.messageHandlers.shion.postMessage({type: 'send', data: base64})`。noVNC 交来的是它发送队列的一个视图，会被复用，所以当场编码。
- App → 页面：`callAsyncJavaScript("shionVNC.channelReceived(b)")`，一次一个，按顺序；上一个还没执行完时到的消息，攒到下一次一起交，但每条消息一个字符串，不拼成一块（见「发现」第 2 条）。
- `WKScriptMessage` 不能直接带二进制：头文件写着 `body` 只能是 NSNumber、NSString、NSDate、NSArray、NSDictionary、NSNull；Apple 的工程师 2026 年 6 月在开发者论坛上也确认 `postMessage` 不能传 ArrayBuffer。所以现在两个方向都是 base64。
- **base64 不慢。** macOS 27 上，8 MB 在 App 里编成 base64、经 `callAsyncJavaScript` 交给页面、页面用 `Uint8Array.fromBase64` 解开，一共 13 毫秒（1 MB 2 毫秒）。实际解码时，丙只比甲慢 8%，外壳进程的 CPU 一样（见「解码吞吐」）。
- **macOS 27 的 SDK 新加了一条 App → 页面的通路，但不是给字节用的。** `-[WKUserContentController addBuffer:(NSData *) name: contentWorld:]`（Swift 里是 `add(_: WKJSScriptingBuffer, name:contentWorld:)`），配一个 `removeBufferWithName:contentWorld:`，头文件说「JavaScript 通过 `window.webkit.buffers.<name>` 拿到这块数据」。在 macOS 27.0.1 上试了：页面拿到的是 `[object WebKitBuffer]`，不是 ArrayBuffer，没有 `byteLength`。WebKit 的源码（`Source/WebCore/page/WebKitBuffer.idl`）里它只有 `asUTF16String()` 和 `asLatin1String()` 两个方法，是给大段字符串用的；要拿字节只能 `asLatin1String()` 再逐个字符转，不会比 base64 快。同一版还加了 `WKJSHandle`（让 App 拿着页面里 JS 对象的引用），也不是传字节用的。
- 关闭：页面 `close(1000)` → App 发 1000（交还）；`close()` 不带码 → App 直接断，不发关闭帧（租约留着），和浏览器的 WebSocket 一样。
- 测过：Chrome、WebKitGTK 里画面、打字、交还 1000、4000 传到页面；macOS 27 的 WKWebView 里画面、交还 1000（4000 没过，毛病在 App 一侧的传输，「发现」第 11 条）。
- App 一侧的 WebSocket 用原生的 `URLSessionWebSocketTransport`（`claude/rfb` 分支）：Access 头、超时、错误里不带 URL、收得到 4000，都已经做好、测过；它一条 WebSocket 消息交一次（`Inbox` 不拼接），正好一条一个字符串交给页面。按代码看能直接用，这个组合没测过。

### 别的办法（没做）

- `WKURLSchemeHandler` 做不了 WebSocket。可以让页面 `fetch('shion-webvnc://stream')`，scheme handler 一直不结束、边收边 `didReceive(data)`，页面读 `response.body` 的流，这样 App → 页面是二进制、不用 base64；页面 → App 还是走 postMessage。WebKit 是否真的边收边交给页面没验证。

### 逐条看安全

| 问题 | 甲（中转） | 丙（HostChannel） | 原生 rfb/ |
| --- | --- | --- | --- |
| 本机端口能不能被别的进程连上 | 有端口；128 位一次性令牌 + Origin + 只接一条，测过拒绝（Linux、macOS） | 没有端口 | 没有端口 |
| 浏览器里的网页能不能连 | Chrome 已经有 Local Network Access：公网来源的网页连 127.0.0.1 要用户同意（测试里得关掉这个检查）。WebKit 现在没有；以后有了，自定义 scheme 的页面算不算「公网」不确定，甲可能突然连不上 | 不相关 | 不相关 |
| ticket、service token 会不会进网页 | 不会：页面只有 `ws://127.0.0.1:端口/` 和子协议令牌 | 不会 | 不相关 |
| 会不会进日志、崩溃报告 | 中转不记 URL 的问号后面、不记头的值。WebContent 崩溃报告里最多有页面地址（`shion-webvnc://app/…`）和中转地址，没有 ticket | 同左，连中转地址都没有 | 错误里不带 URL（`bad287b` 起） |
| 解码在哪 | WebContent 进程（有沙盒） | 同左 | App 进程（Shion 不开沙盒） |
| 恶意服务器 | 要先打穿 WebKit（JS 引擎、JPEG 解码器）再逃出沙盒，才碰得到 App 的数据 | 同左 | Swift 有边界检查；尺寸、解压都有上限；zlib 是系统的 C 库。出事就是 App 的全部权限 |
| 拒绝服务 | noVNC 的接收队列最多 40 MiB，超了就断开；画面过大时 WebContent 进程可能被系统杀掉，App 本身不受影响（WKWebView 会收到进程终止的回调） | 同左 | 尺寸、解压、剪贴板都有上限（`bad287b`） |
| 引入的代码 | 一个浏览器引擎（系统的 WebKit，随 macOS 更新）+ noVNC（约 750 KB JS） | 同左 | 约 2900 行自己的 Swift |

## 和原生 rfb/ 逐项对比

### 性能（Linux 实测；解码吞吐也有 macOS）

testbed：Xvnc 1.13.1，参数照 Hermes 的 `launcher.sh`，1440×900，经 Hermes 自己的 `rfb_filter.py`；4 核容器。原生是 `rfb-probe`（`rfb/` 在 `bad287b`，release 构建）；noVNC 是无头 Chrome 153（软件绘制）里的这个页面。三次取中位数，原始数据在 `results/linux-measure.json`。「Chrome 滚动」：远端一个 1440×900 的 Chrome 打开 `linux/scenes/article.html`（中日英文字，每隔几段一张照片一样的图），每 100 毫秒滚一格，滚 5 秒，前后各留一点时间，共 6.5 秒。CPU：原生是 `rfb-probe` 进程；noVNC 是整个 Chrome 进程树（渲染、GPU、浏览器进程）；中转、通道的 App 一侧单列。

| 场景 | 客户端 | 首帧 | 帧（FramebufferUpdate） | 下行 | 客户端 CPU | App 一侧 CPU | Xvnc CPU |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 静止 5 秒 | 原生（ZRLE） | 7 ms | 2 | 10 KB | 0.04 s | — | 0.01 s |
| | noVNC 甲（Tight+JPEG） | 22 ms | 5 | 112 KB | 0.11 s | 0.10 s | 0.00 s |
| | noVNC 丙 | 42 ms | 5 | 112 KB | 0.11 s | 0.12 s | 0.01 s |
| | noVNC 只用 ZRLE | 29 ms | 2 | 10 KB | 0.13 s | 0.10 s | 0.00 s |
| Chrome 滚动 | 原生（ZRLE） | 7 ms | 81 | 42.8 MB | 1.03 s | — | 3.95 s |
| | noVNC 甲（Tight+JPEG） | 24 ms | 262 | 33.6 MB | 5.84 s | 0.43 s | 1.38 s |
| | noVNC 丙 | 54 ms | 221 | 33.3 MB | 6.18 s | 2.25 s | 1.36 s |
| | noVNC 只用 ZRLE | 25 ms | 74 | 39.2 MB | 3.84 s | 0.38 s | 3.86 s |
| 静止，150 ms 往返 | 原生 | 308 ms | 2 | 10 KB | 0.04 s | — | 0.01 s |
| | 原生，不一次发完握手 | 685 ms | 2 | 10 KB | 0.05 s | — | 0.00 s |
| | noVNC 甲 | 708 ms | 39 | 71 KB | 0.25 s | 0.13 s | 0.01 s |
| | noVNC 丙 | 715 ms | 39 | 72 KB | 0.24 s | 0.23 s | 0.01 s |
| Chrome 滚动，150 ms 往返 | 原生 | 310 ms | 55 | 28.4 MB | 0.75 s | — | 2.95 s |
| | noVNC 甲 | 705 ms | 156 | 21.5 MB | 4.20 s | 0.32 s | 1.08 s |
| | noVNC 丙 | 716 ms | 119 | 16.8 MB | 3.79 s | 1.30 s | 1.05 s |
| | noVNC 只用 ZRLE | 714 ms | 50 | 26.3 MB | 2.77 s | 0.33 s | 2.96 s |

怎么读：

- **流畅度和流量是编码决定的。** 同样只用 ZRLE，noVNC 和原生的帧数一样（74 对 81）。Tight+JPEG 在 Chrome 滚动时帧数是 3.2 倍，每帧小 76%（128 KB 对 528 KB），总流量少 21%，服务器编码的 CPU 少三分之二。原生要追上，就要做 Tight+JPEG（`rfb/README.md` 本来就列在「以后」，JPEG 用 ImageIO 解）。
- **同样的数据，原生解码便宜得多。** ZRLE 每帧：原生约 13 ms，noVNC 约 52 ms。Tight+JPEG 的 noVNC 每帧约 22 ms。这是 Linux 上的无头 Chrome，绘制全靠 CPU。Mac 上的 WKWebView 快不少（下面的解码吞吐），但没在 Mac 上和原生比过。
- **首帧：远的线路上原生快一倍多。** noVNC 的握手一来一回（和原生关掉「一次发完」时一样，685 ms 对 708 ms）。
- **丙比甲慢一点，在 Mac 上几乎一样。** Chrome 里丙要经过测试脚本的 CDP 调用，App 一侧的 CPU 也算的是 Node；在线路慢、帧多的时候，丙收到的帧少一些（119 对 156）。WKWebView 的脚本桥没有这一层：解同一段录像，丙只比甲慢 8%（见下）。
- **静止时 Tight 反而多发**：JPEG 是有损的，画面停下后 Xvnc 再无损补一遍（112 KB 对 10 KB）；150 ms 往返时这一遍被拥塞控制切成几十个小更新（39 帧）。

**解码吞吐。** 把一段录好的 Chrome 滚动（CI 第 2 次运行时在 Linux 上录的，87 帧、17.8 MB 的 Tight+JPEG）一口气喂给页面，从连接到解完最后一帧的时间。三种引擎用同一段录像、同一种计时（每 50 毫秒问一次页面解到第几帧）；Linux 上三次取中位数，macOS 跑了一次。CPU 分开记：网页进程（Chrome 的 renderer、WebKitGTK 的 WebKitWebProcess、macOS 的 WebContent）和 App 一侧。原始数据在 `results/linux-decode.json`（`linux/decode.mjs`）和 `results/macos-selftest.json`。

| 引擎 | 甲（中转） | 丙（HostChannel） | 网页进程 CPU（甲 / 丙） | App 一侧 CPU（甲 / 丙） |
| --- | --- | --- | --- | --- |
| WKWebView，macOS 27.0.1（CI 的 Apple Silicon，`xcode-27-arm64`） | 0.99 s | 1.07 s | 1.14 s / 1.20 s | 外壳进程 0.21 s / 0.20 s |
| 无头 Chrome 153，Linux（4 核 Xeon 2.1 GHz，软件绘制） | 1.52 s | 2.33 s | 1.59 s / 1.94 s | 中转 0.14 s / Node 经 CDP 0.62 s |
| WebKitGTK 2.52.6，Linux（同一台，Xvfb，软件绘制） | 2.75 s | 2.75 s | 5.73 s / 5.47 s | 中转 0.14 s / UI 进程 2.19 s |

- Mac 上大约 17 MB/s。按 Linux 上实测的滚动码率（noVNC 约 5 MB/s）折算，WKWebView 解码大约占一个核的三分之一。这是估算，没在 Mac 上连着看过。
- WebKitGTK 的 UI 进程在甲的时候也用了 2.07 s，大多是 GTK 用 CPU 画网页，所以丙的 App 一侧在 WebKitGTK 里也几乎不花钱。
- 机器不同（Mac 是 CI 的 Apple Silicon，Linux 是 4 核容器），横着比的不只是引擎。
- 原生没有 Tight，不能比这一项。

### 功能

| 方面 | 网页（noVNC + 这里的页面） | 原生 rfb/ |
| --- | --- | --- |
| 中文、日文输入 | noVNC 自己不支持输入法拼写：桌面浏览器里画布不是可编辑元素，输入法根本不启动，按键照原样发出去。直接打出来的非拉丁字符（某些键盘布局、⌥ 组合），noVNC 逐字发 Unicode keysym（`0x01000000 + 码点`），Xvnc 要临时给它分配键位，这就是 TigerVNC #93 说的那条路。这里的页面加了输入法文本框，拼好的字走「剪贴板 + Ctrl+V」，测过：拼写中不发，确认的「你好」到了远端的 Chrome 文本框；表情面板、粘贴也一样 | 打算一样（`NSTextInputClient` + 「剪贴板 + Ctrl+V」），还没做 |
| 剪贴板 | 扩展剪贴板（UTF-8），先 Notify、等 Xvnc 来要再 Provide，和原生一样。只看时连上、中途接管后粘贴也能用（Xvnc 对没声明能力的客户端用默认能力），测过。`-SendCutText=0`，远端复制的东西拿不回来，两边一样 | 一样，每次粘贴前再声明一次能力 |
| 键位 | noVNC 发 QEMU 扩展按键（keysym + 键的位置）；Xvnc 默认 `RawKeyboard=0`，按 keysym 映射，所以 Mac 的键盘布局不影响打出来的字（测过：AZERTY 的 a 在 QWERTY 的 q 位置上，远端得到 a） | 只发 keysym，同样不受布局影响 |
| ⌘ 当 Ctrl | 页面做（noVNC 默认把 ⌘ 当 Alt）；⌘Q 这些留给 Mac 靠 WKWebView 子类。macOS 27 上用真的 NSEvent 测过 ⌘A、⌘Q、⌘V | 打算一样 |
| 光标 | noVNC 总是请求 Cursor 伪编码：接管时光标在本地画（不跟着网络卡）；只看时 Xvnc 画助手的指针、给我们空光标，页面显示一个小圆点代替本地指针 | 只看时不请求（Xvnc 画助手的指针），接管时请求 |
| 缩放 | noVNC 的 `scaleViewport`（CSS 缩放画布） | IOSurface + `contentsGravity` |
| 关闭码 | noVNC 不报；页面从 socket（甲）或通道（丙）自己拿到，4000、4401、4403 在 Linux 上测过。macOS 上要看 App 一侧的传输：Network.framework 拿不到 4000（「发现」第 11 条），要用 URLSession | `URLSessionWebSocketTransport` 在 macOS 上拿得到 4000，Network.framework 拿不到（`claude/rfb` 分支 `rfb/README.md` 第 15 条）。两边都要在没有关闭码时看租约 |
| 鼠标侧键 | 要拦下（发现第 1 条） | 不受影响 |
| 首帧 | 握手一来一回 | 握手一次发完 |

### 维护

- noVNC 在维护：1.7.0 是 2026 年 4 月发的，之后一直有每日构建；官方桌面端钉在 1.7.0。升级就是改 `fetch-novnc.sh` 里的版本和 sha512，再跑一遍测试。
- 页面碰了 noVNC 的几个内部成员：统计帧数包了 `_framebufferUpdate`（只为测量），粘贴前看 `_clipboardServerCapabilities*`（防止扩展剪贴板不在时把中文变成「?」），测量时换 `_sendEncodings`。升级时要复查这几处；其余用的是公开接口和导出的 `Keyboard` 类。
- **MPL-2.0**：noVNC 的文件原样打包（JS 本身就是源码形式），带上 `LICENSE.txt` 和 `docs/LICENSE.*`，说明从哪来，就满足了。要是改了 noVNC 的某个文件，那个文件改过的源码要公开（文件级的 copyleft，不传染到我们自己的文件）。这里一个字都没改，`fetch-novnc.sh --check` 能证明。pako 是 MIT。
- 原生：协议、解码、传输约 2900 行，都是自己的；要补 Tight+JPEG、显示层、输入法。没有外部依赖要跟。

### 接进 App 的工作量

| | 网页 | 原生 |
| --- | --- | --- |
| 已经有的 | 页面（约 500 行 JS，含输入法、⌘、粘贴、关闭码）、甲和丙两套 App 一侧（Swift 约 550 行，外壳里）、Linux 和 macOS 的测试 | 协议、ZRLE、传输、测试（`rfb/`） |
| 还要做的 | 把外壳里的 WKWebView 子类、scheme handler、ChannelHost 搬进 App（`NSViewRepresentable`），ChannelHost 的上游换成原生的 `URLSessionWebSocketTransport`；接 gateway 的 `display.*` 和租约（两边一样）；noVNC 打包进 App。估计 3–5 天 | 显示层（约 1 周）、接管和输入法（约 1 周）、Tight+JPEG（2–3 天）；租约部分两边一样 |

## 发现

都在 Linux 的 testbed 上实测过，除非另外说明。

1. **noVNC 的鼠标侧键会把 Hermes 的过滤器弄坏（TigerVNC 1.15 起）。** noVNC 1.6 起支持 ExtendedMouseButtons（伪编码 -316）：服务器支持时，按下后退、前进键，它发 7 字节的 PointerEvent（按钮字节的最高位做标记，后面多一个字节）。Hermes 的 `rfb_filter.py` 把 PointerEvent 固定当 6 字节，第 7 个字节被当成下一条消息的类型：后退键（0x01）是未知类型，桥用 1003 关掉画面；前进键（0x02）被当成 SetEncodings 的开头，后面的输入都被吞进一个假的 SetEncodings 再交给 Xvnc（`linux/filter_check.py`）。testbed 的 Xvnc 1.13.1 不支持 -316，所以这里碰不到；TigerVNC 1.15 加了侧键支持，VPS 上的版本要看发行版。官方桌面端也受影响。这里的页面把侧键拦下；Hermes 那边最干净的修法是让过滤器从客户端的 SetEncodings 里删掉 -316（它本来就在解析 SetEncodings）。原生客户端不声明 -316，不受影响。
2. **noVNC 握手结束和后面的数据在同一条消息里时，它会停下。** noVNC 在「连接中」状态下读完握手（变成「已连接」）就不再读同一条消息里剩下的字节，要等下一条消息来了才接着读。真的 Xvnc 不会这样发（客户端不请求它不发东西），但回放录像时会：`rfb/testbed/replay_server.py` 把录像按 64 KiB 切块发，noVNC 就卡在握手之后。所以这里录的时候记下每条 WebSocket 消息的边界，用 `replay_messages.py` 原样回放；HostChannel 攒批时也保持一条消息一个字符串。
3. **Chrome 的 Local Network Access。** Chrome 153 默认不让公网来源的页面连 `ws://127.0.0.1`（`ERR_BLOCKED_BY_LOCAL_NETWORK_ACCESS_CHECKS`），测试里用 `--disable-features=LocalNetworkAccessChecks` 关掉。WKWebView 现在没有这个检查，但这是甲方案的一个长期风险；丙不受影响。
4. **Xvnc 按 keysym 打字，不按键的位置。** noVNC 发 QEMU 扩展按键（keysym 和键码一起），Xvnc 的 `RawKeyboard` 默认是 0，Hermes 没改，于是按 keysym 在自己的键盘布局里找键。Mac 用什么布局都打得对。反过来，要是有人给 Xvnc 开了 `-RawKeyboard`，就会按键的位置打字。
5. **只看时连上、中途接管，粘贴照样能用。** noVNC 在连上时回复剪贴板能力，只看时这条被桥丢掉；接管后它直接发 Notify，Xvnc 用默认能力照样来要文字。官方桌面端接管时不重连，所以这一点很重要；测过。
6. **noVNC 的 `disconnect()` 不带状态码地关 socket。** 桥只在 1000 / 1001 时交还租约，所以「关掉画面就交还」要先自己 `close(1000)`（官方也是这么做的）。想保留租约（比如只是重连）就直接 `disconnect()`。
7. **Network.framework 的 WebSocket 服务端看不到请求路径**，只给子协议和请求头，所以甲的令牌放在子协议里。macOS 27 上 WKWebView 连中转时带的头：Origin（`shion-webvnc://app`）、User-Agent、Accept、Accept-Encoding、Accept-Language、Cache-Control、Pragma、Sec-Fetch-Dest / Mode / Site、Sec-WebSocket-Extensions，没有 Cookie。被拒的连接 `NWListener` 直接断开，不回 HTTP 状态。
8. **自定义 scheme 的页面是安全上下文。** macOS 27 的 WKWebView 里，`shion-webvnc://app` 的页面 `isSecureContext` 为真，`crypto.subtle` 在，`Uint8Array.fromBase64` 在；WebKitGTK 也一样（不管有没有 `register_uri_scheme_as_secure`）。WebSocket 的 Origin 是 `shion-webvnc://app`。所以 noVNC 「需要安全上下文」的要求在 App 里不是问题。
9. **静止画面 Tight 比 ZRLE 多发十倍**（无损补画，见上面的表）。
10. **noVNC 只看时会把本地鼠标藏起来**（Xvnc 给的是空光标）。页面在只看时打开 `showDotCursor`。
11. **macOS 上 Network.framework 的 WebSocket 客户端收不到服务器先发的关闭帧，关闭前的最后一条消息也丢了。** macOS 的 CI 上回放 17 条消息后用 4000 关闭：甲和丙的上游（`NWConnection` + `NWProtocolWebSocket`，一直挂着 receive）都只交上来前 16 条，接着报 `ENOTCONN`（Socket is not connected）。第 17 条（368 字节）和关闭帧都没交上来，页面只看到 1006。原生 `rfb/` 碰到的是同一个问题（`claude/rfb` 分支 `rfb/README.md` 第 15 条）：Network.framework 拿不到；URLSession 一直挂着 receive 就拿得到 4000，关闭前的帧一帧不少。原生 App 已经改用 `URLSessionWebSocketTransport`，网页方案的 App 一侧也该用它。这里的外壳没改：macOS 的 CI 次数用完了，改了也验证不了。
12. **WebKit 和 Chrome 解出来的 JPEG 不完全一样。** 同一段录像，WKWebView 和 Chrome 的画面逐像素比：最大差 3/255，平均差 0.004，没有一个像素差到 16，但像素哈希不同（`cdbe9a9f` 对 `f2edbe99`）。测试要按容差比，不能比哈希。
13. **WebKitGTK 的网页进程在 bubblewrap 沙盒里。** 本机实测：WebKitWebProcess 跑在 `bwrap` 下面，网络命名空间和 PID 命名空间都和外面不同，网页的网络请求都由 WebKitNetworkProcess 代办。GitHub 的 Ubuntu runner 上 bubblewrap 建不起网络命名空间（`RTM_NEWADDR` 失败），网页进程起不来，所以 CI 不跑 WebKitGTK。

## 建议

**原生为主，网页当过渡和备用；不建议长期两套并存。**

- **长期只留原生。** 测量说明：网页的优势（滚动时帧多、流量少、服务器省 CPU）来自 Tight+JPEG，不来自 noVNC 本身；原生补上 Tight+JPEG 之后，帧数和流量应该和 noVNC 相当，解码 CPU 只有它的几分之一，首帧在远的线路上快一倍，键盘、输入法、光标、和 SwiftUI 的整合都完全在自己手里，也不用跟 noVNC 的内部成员和 WebKit 的行为变化（比如本机网络访问限制）。
- **原生下一步的顺序**：显示层 → 接管和输入法 → Tight+JPEG（`rfb/testbed` 现在就能录 Tight 的样本，`record-sample.mjs` 是现成的做法）→ 在真的 Cloudflare 线路上用 `rfb-probe` 量一次。
- **网页的用处**：它现在就能用（只看、接管、中文日文输入都通了），可以在原生的显示层和输入法做完之前，先把云桌面页做出来，放在设置里当「网页查看器」；原生做完后留着当对照和备用，直到原生在真服务器上跑稳，再删掉。两边共用 gateway 的 `display.*`、租约和传输，只有画面和输入不一样，所以留着它当备用花不了多少。要用的话：
  - 用丙（HostChannel），不开本机端口；App 一侧的 WebSocket 就用原生的 `URLSessionWebSocketTransport`（不用 Network.framework，「发现」第 11 条）；
  - WKWebView 子类（不是 SwiftUI `WebView`），URL scheme handler 提供打包的 noVNC（`loadFileURL` 不行），严格 CSP；
  - 页面就用 `web/` 里的这一份，包括输入法文本框、⌘→Ctrl、粘贴、侧键拦截、关闭码；
  - 4000 的处理、限制连续被挤掉的次数，照官方桌面端；
  - 不用乙。
- **要是更看重「不自己造轮子」**，网页也可以当长期方案：功能都有，安全上还多一层沙盒，Mac 上的 WebKit 解码也够快；代价是客户端 CPU 高几倍（笔记本的电池；Linux 上实测，Mac 上没和原生比过）、首帧慢一倍、App 里多一个浏览器引擎，以及上面说的几处要跟 noVNC 的内部成员。
- **该告诉 Hermes 的**：过滤器和 noVNC 的侧键（发现第 1 条），官方桌面端也受影响。

## macOS

`macos/` 是一个最小外壳：AppKit 窗口里一个 `WKWebView` 子类（⌘Q 这些先拦下）、`WKURLSchemeHandler` 提供 `web/`（响应头带 CSP）、`NWListener` 的本机中转（甲）、`ChannelHost`（丙），上游都是 `NWConnection` 的 WebSocket，带 Access 的两个头。macOS 上没有 Xvnc，所以对着 `linux/replay_messages.py` 回放 Linux 上录的 noVNC 会话自检（回放服务器不带这两个头就回 403），结果写进 `results.json`。

CI 上跑了两次（macOS 的分钟数几个会话共用，就用了这两次）：

- 第 1 次（`d006240`，[run 42653757031](https://github.com/xxddff/Shion-Desktop/actions/runs/42653757031)）：编译过了，「页面从 scheme 加载」过了，关第一个窗口时崩了（AppKit 把我们还拿着的窗口释放了），后面的没跑。
- 第 2 次（`5b25ae9`，[run 42655359196](https://github.com/xxddff/Shion-Desktop/actions/runs/42655359196)）：11 项过了 9 项，结果在 `results/macos-selftest.json`。

环境：macOS 27.0.1（26A434），Xcode 27.1，Swift 6.4，WebKit 22625.1.29.11.28，Apple Silicon（runner 镜像 `xcode-27-arm64`）。

| 检查 | 结果 |
| --- | --- |
| 页面从 `shion-webvnc://app` 加载 | 过。57 个文件都从 scheme handler 来；安全上下文、`crypto.subtle`、`Uint8Array.fromBase64` 都有；Origin 是 `shion-webvnc://app`；CSP 头生效（内联脚本不执行，`fetch` 外网被拦） |
| 页面用 `loadFileURL` 加载 | 不行（只记录，不算失败）：8 秒内没有 `ready` |
| 甲：画面、1000 交还 | 过。首帧 63 ms；和 Chrome 解出来的逐像素比，最大差 3/255（「发现」第 12 条）；页面用 1000 关，回放服务器收到 1000 |
| 甲：4000 传到页面 | **没过**：页面看到 1006（「发现」第 11 条） |
| 甲：拒绝别的本机连接 | 过。没子协议、错令牌、对令牌但 Origin 是 `https://evil.example`、对令牌但没有 Origin，都被断开；页面连上之后监听已经关了（ECONNREFUSED） |
| 丙：画面、1000 交还 | 过。首帧 17 ms，画面同上，1000 传到回放服务器 |
| 丙：4000 传到页面 | **没过**：同上，页面看到 1006，理由是上游的 `ENOTCONN` |
| 键盘（真的 NSEvent，经 `NSApp.sendEvent`，窗口是 key window） | 过。`b` → keysym 0x62；⌘A → Ctrl_L + a；⌘Q 交给菜单（Quit 菜单项收到一次），页面没收到；⌘V → 剪贴板 + Ctrl+V（9 个字） |
| 吞吐（同一次 CI 里 Linux 录的 Chrome 滚动，87 帧、17.8 MB） | 甲 0.99 s，丙 1.07 s；WebContent CPU 1.14 s / 1.20 s，外壳进程 0.21 s / 0.20 s |
| `window.webkit.buffers` | `addBuffer:name:contentWorld:` 能调，页面拿到 `[object WebKitBuffer]`，不是 ArrayBuffer（见「丙」）；对照：base64 交 1 MB 用 1.9 ms，8 MB 用 13.4 ms |

外壳的上游没换成 URLSession：换了也没有 macOS 的 CI 次数来验证。

## 怎么复现

```sh
# 一次性：testbed 的依赖（同 rfb/README.md），加上 CJK 字体、Xvfb、openbox、WebKitGTK
sudo apt-get install tigervnc-standalone-server x11-apps x11-utils x11-xserver-utils xterm xdotool xclip \
  fonts-dejavu-core fonts-noto-cjk xvfb openbox gir1.2-webkit-6.0 python3-gi
python3 -m venv ~/testbed-venv && ~/testbed-venv/bin/pip install 'websockets>=13,<18'
/usr/bin/python3 -m venv --system-site-packages ~/wk-venv && ~/wk-venv/bin/pip install 'websockets>=13,<18'
export RFB_TESTBED_PYTHON=~/testbed-venv/bin/python3 WEBVNC_WK_PYTHON=~/wk-venv/bin/python3

cd webvnc
web/fetch-novnc.sh                    # noVNC 1.7.0，校验后解开到 web/vendor/
npm ci                                # playwright-core（已经装了 playwright 也行）
export WEBVNC_CHROMIUM=/usr/bin/google-chrome   # 用 playwright-core 时给它一个 Chrome

node linux/e2e.mjs --out out          # 端到端（20 项）
node linux/record-sample.mjs scroll samples
node linux/webkit.mjs --scroll-sample samples/novnc-scroll.messages.z --out out
node linux/decode.mjs samples/novnc-scroll.messages.z --out out/decode.json   # 解码吞吐（Chrome、WebKitGTK）
python3 linux/filter_check.py         # 过滤器和侧键

# 和原生比：先编 rfb-probe（release）
swift build -c release --package-path ../rfb --product rfb-probe
RFB_PROBE=../rfb/.build/release/rfb-probe node linux/measure.mjs --repeat 3 --out out \
  --clients native,native-nopipe,novnc-relay,novnc-channel,novnc-zrle

# macOS（Xcode 27）
(cd macos && swift build -c release)
macos/.build/release/webvnc-shell --web-root web --python ~/venv/bin/python3 \
  --replay linux/replay_messages.py --static-sample testdata/novnc-static.messages.z \
  --static-expected testdata/novnc-static.expected.png --scroll-sample samples/novnc-scroll.messages.z --out out
```

- testbed 的 Unix socket 路径不能太长；`WEBVNC_RUN` 指定放 socket 的目录（默认 `/tmp`）。
- 远端的 Chrome 用 `google-chrome`（`WEBVNC_REMOTE_CHROME` 可以换）。
- `measure.mjs` 跑一遍约 10 分钟；场景用 `--only static,scroll,scroll-150ms,static-150ms` 选。

## CI

`.github/workflows/webvnc.yml`，只在 `webvnc/**` 或这个文件变化时跑，权限只有 `contents: read`：

- **Linux**（ubuntu-24.04）：取 noVNC 并核对、装 testbed、过滤器检查、Chrome 端到端、录一段 Chrome 滚动（给 macOS 用）、在 Chrome 里给这段录像计时（`decode.mjs`，和同一次运行里 macOS 的吞吐对照）。结果和录像传成 artifact。没有跑和原生的对比（要装 Swift，数据见上）。WebKitGTK 不在 CI 上跑：runner 上它的网页进程沙盒（bubblewrap）建不起网络命名空间，网页进程起不来；这里的 WebKitGTK 结果是在本机跑的，沙盒开着（「发现」第 13 条）。
- **macOS**（xcode-27）：只在手动运行勾选 macos、或提交说明带 `[macos]` 时跑；Linux 没全过也照跑（录像可能还在）。打出 WebKit 的相关头文件、编译外壳、自检、传结果。

## 还没验证

- **真服务器**：经 Cloudflare Tunnel + Access 的 `wss://`，真实的带宽、延迟；VPS 上的 TigerVNC 版本（关系到发现第 1 条）。
- **真的输入法**：Linux 上是 Chrome 的 CDP 模拟的拼写；macOS 的 CI 上没有中文、日文输入法，所以 WKWebView 里真的拼音、日文输入没测，候选窗口的位置也没看。
- **macOS 上的 4000**：App 一侧换成 URLSession 以后，4000 能不能经甲、丙传到页面，没在 macOS 上测（CI 次数用完了）。页面处理 4000 的代码在 Chrome、WebKitGTK 里测过；原生在 `claude/rfb` 上测过 URLSession 收得到 4000。中转往 WKWebView 发关闭帧的这个方向（`NWListener` → 页面）在 macOS 上也还没走到过。
- **丙接原生的 `URLSessionWebSocketTransport`**：按代码看能直接用，没测过。
- **Mac 上的 CPU 和电池**：只有 CI 上的解码吞吐（WebContent 进程的 CPU）；GPU 合成、WindowServer 的开销没量，也没在 Mac 上和原生比（原生的显示层还没做）。
- **Mac 上真用时的焦点**：CI 上窗口是 key window，按键经 `NSApp.sendEvent` 进去；和 App 的其他窗口、全屏、多显示器一起用时没看。
- **乙**：没有做原型。
- **scheme handler 流式传输**（App → 页面不用 base64）没试。`window.webkit.buffers` 的 `asLatin1String()` 没在 macOS 上调过（按源码看不会比 base64 快）。
- **官方桌面端 ⌘V 的实际行为**：是读代码的结论。
