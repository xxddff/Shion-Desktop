# RFB：云桌面的画面客户端

Shion 的「云桌面」要看、要接管 VPS 上助手的 Xfce 桌面。Hermes 用 TigerVNC 的 Xvnc 出画面，经 gateway 的画面桥 `/api/display/ws` 用 WebSocket 传 RFB。这个包是为它写的精简 RFB 客户端：只认这一种服务器，只做用得上的部分。

这是一个独立的 Swift 包，不依赖 App 的任何代码，以后可以用 `git subtree split --prefix=rfb` 原样搬到单独的仓库。说明、测试、测试样本、测试环境都在这个目录里。

现在做完了「探路」和「只看」两步，输入消息的格式也做好、测好了，但还没接界面。macOS 的显示层、接管、输入法是下一步。

## 支持什么

| 部分 | 内容 |
| --- | --- |
| 握手 | RFB 3.8，安全类型 None。默认把我们这边的应答一次发完（见「探路发现」第 5 条） |
| 编码 | Raw、CopyRect、ZRLE（系统的 zlib，做成 `CZlib` system library，Linux 和 macOS 都能链接） |
| 伪编码 | DesktopSize、ExtendedDesktopSize、LastRect；Cursor（接管用，默认不开） |
| TigerVNC 扩展 | Fence（应答服务器的请求）、EnableContinuousUpdates、扩展剪贴板（UTF-8 文本） |
| 输入消息 | KeyEvent、PointerEvent（含滚轮）、ClientCutText（Latin-1 和扩展剪贴板）。格式做对、测好了，还没接界面 |
| 传输 | `URLSessionWebSocketTransport`（App 用：可带 Access 的请求头，一直挂着一个 receive，服务器主动关闭时能拿到关闭码）、`NWWebSocketTransport`（Network.framework，备用：服务器主动关闭时拿不到关闭码，见「探路发现」第 15 条）、`PlainWebSocketTransport`（自带的 `ws://` 客户端，Linux 测试用）、`SocketTransport`（TCP / Unix socket，直连 Xvnc）、`RecordingTransport` / `ReplayTransport`（录样本、放样本） |
| 边界 | 服务器给的尺寸都有上限，分配内存之前先查：屏幕每边 ≤ 8192、总像素 ≤ 7680×4320（`maxScreenDimension` / `maxScreenPixels`）；ZRLE 的压缩长度和解压结果按矩形大小封顶；光标每边 ≤ 512 且热点在图里；名字、拒绝理由这类字符串只留前 4 KiB；服务器发来的剪贴板超过 256 KiB 就跳过（边读边丢，不攒在内存里）；超过 64 字节的 Fence 和 TigerVNC 一样跳过、不回，连接照常 |
| 超时、保活、取消 | 握手 20 秒没完成就断开；运行中每 15 秒发一个 Fence 当 keepalive，15 秒内没回就当连接已死（闲着的桌面什么都不发，没有这个就发现不了）；跑 `handshake` / `run` 的 task 被取消时，按 `closeOnCancel`（默认 1000）关闭连接 |
| 输入顺序 | `post(_:)` 可以从任何线程调用，按调用顺序发出（每个 NSEvent 一个 `post`，按下、抬起、点击、粘贴不会乱序）；也可以直接调用 async 方法，由调用方自己保证顺序 |
| 命令行 | `rfb-probe`：连上去、录下字节流、存一张 PNG |

不做的：SetDesktopSize（会连助手的分辨率一起改）、QEMU 扩展键盘、Tight / JPEG、VNC 密码等认证、颜色表格式。客户端永远请求同一种像素格式：32 位、深度 24、小端，内存里是 B、G、R、X，正好是 IOSurface / CoreGraphics 的 BGRA，也是 Xvnc 在 `-depth 24` 下的原生格式，服务器不用转换。

### 目录

```
rfb/
├ Package.swift
├ Sources/
│ ├ CZlib/        系统 zlib 的 module map
│ ├ RFB/          协议核心，不依赖 Foundation：握手、消息、解码、帧缓冲、PNG
│ ├ RFBNetwork/   传输：Network.framework 和 URLSession 的 WebSocket、自带 ws:// 客户端、TCP / Unix socket
│ └ rfb-probe/    命令行小程序
├ Tests/RFBTests/ 测试；Samples/ 是录下的 Xvnc 会话和对应的真实画面
└ testbed/        测试环境：Xvnc + 画面桥（用 Hermes 自己的 rfb_filter.py）
```

## 用法

App 这边大致是这样（`display.observe` 拿 ticket 由 App 自己的 gateway 连接做）：

```swift
import RFB
import RFBNetwork

// wss://<网关>/api/display/ws?display_ticket=<ticket>；ticket 一次性、30 秒，不写进日志
var request = URLRequest(url: displayURL)
request.setValue(accessClientID, forHTTPHeaderField: "CF-Access-Client-Id")
request.setValue(accessClientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
let transport = try URLSessionWebSocketTransport(request: request)
let client = RFBClient(transport: transport)
let info = try await client.handshake()          // info.width, info.height, info.name（"hermes:<profile>"）

let task = Task {
    do {
        try await client.run { event, framebuffer in
            // 在 RFBClient 这个 actor 上执行，不在主线程。
            switch event {
            case .framebufferUpdated(let dirty):
                // 把 dirty 里的矩形从 framebuffer.pixels 拷进 IOSurface，再通知主线程刷新 layer。
                break
            case .resized(let width, let height):
                break                              // 换一块同样大小的 IOSurface
            case .cursorShape(let cursor):
                break                              // 接管时才有；0×0 表示「隐藏本地光标」
            default:
                break
            }
        }
    } catch let closed as RFBConnectionClosed {
        switch closed.bridgeReason {
        case .controlTaken: break                  // 4000：别人接管了，换新 ticket 回到只看
        case .badTicket: break                     // 4401：ticket 过期或用过了，重新 display.observe
        case .desktopGone: break                   // 4001：桌面没在运行
        default: break                             // 没有关闭码：看租约再决定，见下面
        }
    } catch is CancellationError {
        // 离开画面：task 被取消，客户端已经用 1000 关闭，桥顺带交还租约
    } catch {
        // 其他错误（连不上、keepalive 超时、网络断了）：同样看租约
    }
}

// 输入：每个 NSEvent 一个 post，按顺序发出
client.post(.key(Keysym.forCharacter("a"), down: true))
client.post(.paste("你好", shortcut: [Keysym.controlLeft]))

// 离开画面：取消 task（SwiftUI 的 .task 结束时自动取消），或者 await client.close(.normal)
task.cancel()
```

- **事件回调在客户端的 actor 上同步执行**，回调返回之前帧缓冲不会再变。显示层应在回调里把脏矩形拷走，不要把 `Framebuffer` 存起来：它是写时复制的值类型，存着它会让下一次更新整块复制一次。
- **输入**用 `post(_:)`：不阻塞、可以从任何线程调用，严格按调用顺序发出；`run` 开始之前 post 的会先排着。被拒的输入（超过 256 KiB 的粘贴）直接丢掉，粘贴前先用 `RFBClient.clipboardFits(_:)` 查。也有对应的 async 方法（`sendKey`、`sendKeyPress`、`sendPointer`、`sendScroll`、`sendClipboard`、`paste`），会抛错，但顺序要调用方自己保证。没拿到租约时，桥会把输入直接丢掉，不报错。`Keysym.forCharacter` 把 `NSEvent.charactersIgnoringModifiers` 里的字符换成 keysym：Mac 的 delete 键（0x7F）是 BackSpace，方向键、F1–F24 这类 AppKit 功能键字符也都对上了。
- **剪贴板**：`sendClipboard(text)` 先等 `run` 拿到服务器的剪贴板能力（握手后马上就有），然后宣告有文字（Notify），等 Xvnc 来要（Request）时再把 UTF-8 文字交过去（Provide）。`paste(text)` 是「放进剪贴板 + 按 Ctrl+V」，⌘V 和输入法确认的文字都走它。远端程序处理 Ctrl+V 的那一刻 Xvnc 才来取文字，所以连接要一直开着。超过 256 KiB 直接抛 `RFBError.refusedToSend`，不会发出去让桥断开；服务器没有扩展剪贴板时，非 Latin-1 的文字也直接拒绝，不会悄悄变成「?」。
- **光标**：接管时调 `setCursorShapeUpdates(true)`，交还时调 `false`。
- **连接意外断了，先看租约再决定怎么办。** 关闭码 4000 能直接说明「别人接管了」，`URLSessionWebSocketTransport` 在 macOS 上能拿到它（第 15 条）。但有时候没有关闭码：网络本身断了，或者收的一侧正好因为积压超过 8 MiB 而暂停。这时看 gateway 连接上最新的 `display.lease` 事件（或调 `display.status`）：持有者是别人（`viewer_hash` 不是自己的），就是被挤掉了，回到只看；还是自己，就是画面连接断了，重新接上，控制权还在。
- **`viewer_id` 只在发它的那条 gateway 连接上有效。** Hermes 按 `/api/ws` 连接记着自己发过哪些 id（`tui_gateway/methods_display.py` 的 `_mint_viewer_id` / `_foreign_viewer_id`），`display.observe` 只认这条连接发过的 id，`display.lease.acquire` / `release` 也不认别的连接发的 id。所以：只断了画面连接、gateway 连接还在时，带原来的 `viewer_id` 调 `display.observe`，拿到同一个 id，租约还在你手里；gateway 连接也断了的话，旧 id 不再有用，重连后 `display.observe` 拿新 id，在新连接上再 `display.lease.acquire` 一次（最后接管的人赢）。
- **关闭方式**：`close(.normal)`（1000）和 `.goingAway`（1001）都会让桥交还租约；`.abort` 直接断开、不发关闭帧，桥当成网络断开，租约留在你手里（自带的 ws:// 客户端直接关 socket，Network.framework 用 `forceCancel()`；URLSession 只能用 `task.cancel()`，它会不会仍然发关闭帧、把租约交还，还没验证，见「还没验证」）。客户端自己的超时都用 `.abort`：发送失败后最多再读 2 秒（`sendFailureGrace`），等不到关闭原因就这样断开；握手超时、keepalive 超时也一样。这些情况 `run` 抛 `RFBError.timedOut` 或原来那次发送的错误，不会误交还租约。
- **错误里没有秘密。** 传输层抛的错误只有 `RFBConnectionClosed`（关闭码和理由）、`WebSocketTransportError`（只有 domain 和 code）、`RFBError`、`RFBSocketError`（最多有主机和端口）。Foundation 自己的错误把整个 URL（带 ticket）写在描述里，所以从不原样往外抛。
- **只看时窗口不可见**：直接 `close(.normal)`，只留缩略图。`setContinuousUpdates(false)` 只是改成一问一答，连接开着，服务器仍当有人在看。

### 怎么保证只发桥认得的消息

- 能发的消息是一个封闭的枚举 `ClientMessage`：SetPixelFormat、SetEncodings、FramebufferUpdateRequest、KeyEvent、PointerEvent、ClientCutText（含扩展剪贴板）、EnableContinuousUpdates、Fence。里面没有 SetDesktopSize，也没有 QEMU 消息，想发也构造不出来。
- 发任意消息的 `send(_:)` 不对外。App 只能走几个安全的入口，所以改不了像素格式和编码列表，不会把解码搞坏（`setCursorShapeUpdates` 只增减 Cursor 这一项）。
- 剪贴板消息在编码时检查：压缩后的消息和解压后的文字（换成 CRLF、带结尾的 NUL）都不能超过 256 KiB（桥和 Xvnc 的 `-MaxCutText` 一致）。
- 测试 `BridgeFilterTests` 把我们能构造的每一种消息，按奇怪的分块喂给 Hermes 自己的 `rfb_filter.py`：持有租约时原样通过，只看时输入类消息被丢掉、其他照常通过，从不触发断开。

### 画面桥的关闭码

| 代码 | 意思 | 怎么办 |
| --- | --- | --- |
| 1000 / 1001 | 正常关闭 | 我们关时用 1000（或退出 App 时用 1001），桥都会交还租约 |
| 1003 | 文本帧，或桥分不清边界的消息、超过 256 KiB 的剪贴板 | 不该出现，出现就是 bug |
| 4000 | 别人接管了 | 换新 ticket，回到只看 |
| 4001 | 桌面没在运行 | 显示「已停止」，可以 `display.start` |
| 4401 | ticket 缺了、过期、用过了，或发 ticket 的浏览器标签页已退出 | 重新 `display.observe` |
| 1006 等，或没有关闭码 | 网络断了（macOS 上也可能是拿不到码的 4000） | 看租约（见上面） |

- **服务器自己用 1000 关闭**（不是我们关的）：Xvnc 没了（桌面停了或崩了），桥收尾时用的是默认的 1000。再调一次 `display.status` 看桌面还在不在。
- **4403 不会以关闭码出现**：Host / Origin / 客户端 IP 被拒发生在桥接受连接之前，客户端看到的是升级被拒（HTTP 403），和 Cloudflare Access 拒绝时一样。

## 命令行：rfb-probe

```sh
cd rfb
swift run rfb-probe <url> [选项]
```

- `<url>`：`ws://`、`wss://`（画面桥），`tcp://host:port`，`unix:/path`（直连 Xvnc）。
- `-H 'Name: value'`：加请求头，可以重复；值写成 `@env:变量名` 就从环境变量读，免得进 shell 历史。
- `--out 目录`：输出 `server.bin`（服务器发来的全部字节，也就是测试样本）、`client.bin`（我们发的）、`frame.png`（最后的画面）。
- `--seconds N` / `--updates N`：看多久、收多少帧后停。
- `--no-continuous`、`--no-pipeline`、`--no-extended-desktop-size`、`--encodings zrle,copyrect,raw`：对比用。
- `--transport urlsession|network|plain`：默认在 Apple 平台上用 URLSession，在 Linux 上用自带的 `ws://` 客户端。
- `--paste 文本`：拿到画面后把文字放进远端剪贴板（要持有租约）。
- `--type 文本`：拿到画面后用「剪贴板 + Ctrl+V」把文字打到远端光标处（要持有租约）。
- `--cursor-after 秒数`、`--move-pointer X,Y`：试接管时的光标行为。
- `--keepalive 秒数`：keepalive 的间隔和超时（默认 15，0 关掉）。

在自己的 Mac 上对真的服务器跑一次（**还没在真服务器上试过**）：

```sh
export CF_ID=… CF_SECRET=…                # Cloudflare Access 的 service token
export HERMES_SESSION_TOKEN=…             # Hermes 的会话令牌，用于 /api/ws?token=
swift run rfb-probe --gateway wss://hermes.example.com --profile <助手名> \
  -H 'CF-Access-Client-Id: @env:CF_ID' -H 'CF-Access-Client-Secret: @env:CF_SECRET' \
  --seconds 10 --out probe-out
```

`--gateway` 会先连 `/api/ws`，用 JSON-RPC 调 `display.observe`（带上 `profile`），再拿 ticket 连画面。已经有 ticket 的话，也可以直接把完整的 `wss://…/api/display/ws?display_ticket=…` 当作 `<url>`，但 ticket 只有 30 秒。程序不打印 ticket、`viewer_id`、令牌和请求头的值，URL 只显示问号前面的部分，错误只显示 domain 和 code（Foundation 的错误描述里有完整 URL）。令牌和 ticket 照 App 的 `ServerSettings.socketURL` 做百分号编码（`URLQueryItem` 不编「+」，服务器会读成空格）。跑完把 `probe-out/` 里的 `server.bin` 留下，就是一份真服务器的样本，能拿来加测试。

## 测试环境（testbed）

在 Linux 上搭一个尽量像服务器的环境：TigerVNC 的 Xvnc，参数照 Hermes 的 `tools/bot_desktop/launcher.sh`（`-SecurityTypes None -AlwaysShared -AcceptSetDesktopSize -FrameRate 30 -SendCutText=0 -MaxCutText 262144`，只监听 Unix socket），前面放 `bridge.py` 当画面桥。`bridge.py` 照 `hermes_cli/web_routers/display.py` 写：ticket 放在 `?display_ticket=`、一次性、30 秒；用 `testbed/hermes/rfb_filter.py`（从 Hermes 原样复制，MIT，记着来源的 commit）过滤客户端发的字节；关闭码 4401 / 4001 / 1003 / 4000 和真的一样；持有租约的人用 1000 / 1001 关闭时交还租约，断网不交还。

```sh
sudo apt-get install tigervnc-standalone-server x11-apps x11-utils x11-xserver-utils xterm xdotool xclip fonts-dejavu-core
python3 -m venv ~/testbed-venv && ~/testbed-venv/bin/pip install 'websockets>=13,<18'
export RFB_TESTBED_PYTHON=~/testbed-venv/bin/python3   # 系统 python 有 websockets 13 以上的话可以不设

rfb/testbed/start.sh                                     # 前台运行，Ctrl-C 全部停掉
swift run --package-path rfb rfb-probe "$(rfb/testbed/observe.sh)" --seconds 5
```

- `observe.sh [viewer_id]` 相当于 `display.observe`，打印一个带新 ticket 的 `ws://` 地址。
- 租约：`curl 'http://127.0.0.1:8765/lease/acquire?viewer_id=me'`、`/lease/release`、`/lease`。拿 `observe.sh me` 的地址连上，就是持有租约的人。
- 环境变量：`RFB_TESTBED_DISPLAY`（默认 `:21`）、`RFB_TESTBED_PORT`（8765）、`RFB_TESTBED_GEOMETRY`（1440x900，和 Hermes 默认一样）、`RFB_TESTBED_SCENE=static`（画面不会自己变，录样本用）、`RFB_TESTBED_REQUIRE_HEADER=CF-Access-Client-Id`（不带这个头就 403，像 Cloudflare Access）、`RFB_TESTBED_LATENCY_MS=150`（加一个往返延迟，模拟远的 Cloudflare 线路）。
- `smoke.sh`：端到端检查，CI 也跑它。不带 Access 头会被拒（403）；只看的人能看到画面，粘贴进不去；同一张 ticket 第二次用被 4401 关掉；持有租约的人粘贴的中文、日文、emoji 原样到了 X 的剪贴板；用 1000 关闭后租约交还。装了 Chrome 或 Chromium 时（GitHub 的 Ubuntu runner 上有）再加一步：用「剪贴板 + Ctrl+V」往浏览器的文本框里打一段中文、日文、emoji，从窗口标题读回来对比。
- `record-sample.sh 名字 脚本 [rfb-probe 选项]`：录测试样本。起一个静止的桌面，`rfb-probe` 连上去录字节流，同时用脚本挪窗口、滚终端、换背景、改分辨率，最后用 `xwd` 抓真实的屏幕。
- `replay_server.py`：不需要 Xvnc，把录好的样本经 WebSocket 放出去，然后用 4000 关闭或者等客户端关。macOS 上没有 Xvnc，传输层的测试靠它。

## 测试

```sh
cd rfb
swift test                                         # 不设 RFB_TESTBED_PYTHON 时跳过 WebSocket 那组
RFB_TESTBED_PYTHON=~/testbed-venv/bin/python3 swift test
```

- **样本**（`Tests/RFBTests/Samples/`）：在 testbed 上录的四段 Xvnc 1.13.1 会话。`watch`：ZRLE、CopyRect、连续更新、Fence；`resize`、`resize-plain`：xrandr 改分辨率，分别走 ExtendedDesktopSize 和 DesktopSize；`raw`：只要 Raw 和 CopyRect、一问一答。每段都有 `xwd` 抓的真实屏幕。测试把样本放一遍，解出来的画面要和真实屏幕逐像素一致，只允许光标附近不同：Xvnc 会把指针画进画面，`xwd` 不会（`raw` 样本里就能看到 xterm 的 I 形光标）。还会把样本切成 1 字节、7 字节这种奇怪的块再放一遍，结果必须一样。`*.png` 是解出来的画面，给人看的。
- **ZRLE**：每种子编码（raw、solid、2/3/16 色调色板、plain RLE、调色板 RLE）、64×64 分块和边缘的小块、跨矩形延续的 zlib 流、各种坏数据。
- **消息**：每种客户端消息的字节、剪贴板大小限制、扩展剪贴板的来回、Fence 应答、连续更新只在服务器支持时打开、握手失败、流水线握手、光标形状。
- **画面桥**：见上面「怎么保证只发桥认得的消息」。需要 python3。
- **WebSocket 传输**：对 `replay_server.py` 跑：请求头、被拒的升级（403）、4000 传到调用方、关闭前的画面一帧不少、我们关闭时发 1000。macOS 上测 `URLSessionWebSocketTransport`、`NWWebSocketTransport` 和自带的客户端，Linux 上只测自带的（见下一节）。只有 Network.framework 收 4000 的那一项标成了「已知问题」（第 15 条）；各传输实际报了什么会打印到 stderr。另外：明文 `ws://` 只能带着请求头连回环地址、scheme 不分大小写、Foundation 错误去掉 URL、服务器帧长度最高位为 1 时不崩、服务器不回升级时按时放弃。
- **边界**：超大的屏幕、DesktopSize、ZRLE 长度、ZRLE 解压炸弹、服务器剪贴板（老式和扩展）、名字和拒绝理由、光标尺寸和热点，都在分配之前被挡下或跳过；超过 64 字节的 Fence 跳过、不回，后面的消息照常解。
- **连接结束**：写的一侧先坏、读的一侧还排着关闭帧时（包括流水线握手刚发出去就失败、桥接着用 4401 关闭），客户端照样读完、报出关闭码，之后不会再自己 abort；一直等不到原因时，宽限期后用 `.abort` 断开，报原来那次发送的错误，不会误交还租约；握手超时、keepalive 超时报 `timedOut`；取消 task 时按 `closeOnCancel` 关闭；超大的粘贴被拒不算连接出错。时间相关的测试在 CPU 被占满的情况下也连跑了十遍。
- **输入顺序**：`run` 开始前后混着 post 的按键、指针、粘贴，发出去的顺序和 post 的顺序完全一样。

### 在 Linux 上编译

容器和 CI 都直接用 swift.org 的工具链（6.4.2，Ubuntu 24.04）：

```sh
curl -fsSL https://download.swift.org/swift-6.4.2-release/ubuntu2404/swift-6.4.2-RELEASE/swift-6.4.2-RELEASE-ubuntu24.04.tar.gz | tar xz
export PATH=$PWD/swift-6.4.2-RELEASE-ubuntu24.04/usr/bin:$PATH
```

要 `zlib1g-dev`。协议核心不用 Foundation。Linux 上 Foundation 的 `URLSessionWebSocketTask` 能编译，但跑起来报「WebSockets not supported by libcurl」：Ubuntu 的 libcurl 没开 WebSocket。所以 Linux 上的测试和 `rfb-probe` 用自带的 `PlainWebSocketTransport`（只支持 `ws://`，没有 TLS），App 在 macOS 上用 `URLSessionWebSocketTransport`。Network.framework 只有 Apple 平台有，Linux 上编不到；在容器里可以拿一个只声明了用到的 API 的替身模块做类型检查。

### CI

`.github/workflows/rfb.yml`，只在 `rfb/**` 或这个文件变化时跑：

- **Linux**（ubuntu-24.04）：装 Swift（缓存；下载的 tarball 按钉住的 SHA-256 校验，这个值钉之前对过 swift.org 的 PGP 签名）、`swift build`、`swift test`（含 WebSocket 测试），再装 Xvnc 跑 `testbed/smoke.sh`。工作流只要 `contents: read` 权限，`websockets` 限定在 13 到 17。
- **macOS**（`xcode-27`）：`swift build`、`swift test`，确认 Apple 平台能编，看两个 Apple WebSocket 传输的实际行为。macOS 的分钟数有限，只在手动运行时勾选 macos，或提交说明里带 `[macos]` 时才跑。这次任务一共跑了 4 次（第 2 次卡住，手动取消）：编译和核心测试全过；传输层的结果见「探路发现」第 15 条。

## 探路发现

都在 testbed 上实测过（Xvnc 1.13.1，Ubuntu 24.04；Hermes 服务器上的 TigerVNC 版本取决于 VPS 的发行版）。标了「和 README 不同」的，是和仓库根目录 README 里写的不一样的地方。

1. **远端的剪贴板拿不回来。和 README 不同。** Hermes 用 `-SendCutText=0` 启动 Xvnc（怕只看的人拿到持有者复制的东西），服务器根本不往外发剪贴板，接管时也不发。实测：远端 `xclip` 放进剪贴板，持有租约的连接也收不到任何东西。所以 README 里「⌘C 反过来，远端复制完把内容取回 Mac」现在做不到。可选的路：请 Hermes 改成只给持有者发（Xvnc 做不到按连接区分，要桥解析服务器发来的字节流，把 ServerCutText 只转给持有者）；或者加一个 gateway 方法读远端剪贴板。往远端粘贴不受影响。
2. **扩展剪贴板只能「先宣告、等对方要」。** Xvnc 宣告的能力是：只支持文本；动作 request / peek / notify / provide；文本的「不请自来的最大长度」是 0。所以不能直接把文字推过去，要先发 Notify，等远端程序粘贴、Xvnc 发 Request 时再 Provide。中文、日文、emoji、换行原样到达（`smoke.sh` 第 4 步）。「剪贴板 + Ctrl+V」打进 Chrome 的文本框也一字不差（第 5 步），README 里输入法的做法走得通。只看时桥会丢掉我们发的所有 ClientCutText，包括连接时的能力声明，所以每次粘贴前再发一次能力声明。
3. **Fence 必须应答；不声明 Fence 就没有连续更新。** 声明了 Fence，Xvnc 一连上就发一个 Fence 请求，之后大约每帧两个，用来量往返时间、做拥塞控制。实测 12 秒：不声明 Fence 时 Xvnc 不发 EndOfContinuousUpdates，只能一问一答（35 帧）；声明了却不应答，1.2 秒、5 帧之后画面就停了；正常应答，连续更新一直在走（37 帧）。所以两个都用：声明 Fence 并照规矩应答（只回 BlockBefore / BlockAfter，不支持 SyncNext，和 noVNC 一样），收到第一个 EndOfContinuousUpdates 后打开连续更新，分辨率变了就按新尺寸重发一次。
4. **连续更新在远的线路上明显更好。** 给桥加 150 ms 往返延迟，在 Chrome 里滚动同样的距离：连续更新收到 47 帧，一问一答只有 24 帧。一问一答每帧至少要等一个往返。
5. **握手可以一次发完，首帧快一倍多。** RFB 3.8 + None 的握手是一来一回好几趟，150 ms 往返时首帧要 686 ms。我们的应答是固定的（3.8、None、共享、像素格式、编码列表），Xvnc 又是按字节流读的，所以连上就一次发出去，首帧降到 310 ms。经过 Hermes 的过滤器没问题（它本来就按字节流解析握手的 14 个字节）。服务器要是想要别的版本或认证，照样握手失败。可以用 `pipelineHandshake = false` 关掉。
6. **ZRLE 的带宽：静止时很省，浏览器滚动时很费。** 1440×900，Chrome 打开一页文字：首帧约 180 KB；加一张照片一样的噪点图，首帧约 1 MB。滚动 5 秒收到 68 帧、12.8 MB，平均每帧约 190 KB，约 2.5 MB/s（20 Mbit/s）。Chrome 滚动时 Xvnc 认不出平移，没有 CopyRect，整块重发。拥塞控制会在慢的线路上自动少发帧，所以不会越积越慢，而是变得一顿一顿的。官方桌面端用的 noVNC 会和 Xvnc 协商 Tight + JPEG（画质 7），照片类的内容会小很多，文字帮助不大。建议先用 `rfb-probe` 在真的 Cloudflare 线路上量一次再决定要不要做 Tight。
7. **只看时 Xvnc 会把助手的指针画进画面**（不声明 Cursor 伪编码时），样本里能看到。这和 README 的打算一致。testbed 的根窗口没有窗口管理器设置光标，所以停在桌面背景上时什么也不画；Hermes 的 Xfce 桌面上有箭头。
8. **中途打开 Cursor 伪编码立刻生效，但 Xvnc 按「谁在动指针」决定。** README 第 5 条风险问的就是这个。实测：重新发带 Cursor 的 SetEncodings，1 ms 内就收到光标消息；但只要指针的位置不是我们最后一次 PointerEvent 的位置（助手动的），Xvnc 就继续自己画，发给我们一个 0×0 的空光标。持有租约、自己动了指针以后，2 ms 内收到真的光标（xterm 的 I 形，9×16，热点 4,8），Xvnc 也不再画。所以显示层收到 0×0 就藏起本地光标，收到图就画。只看时一直开着也能用，但为了稳妥，还是照 README 的打算：接管时开、交还时关。
9. **桥还认 QEMU 扩展键盘（255），SetDesktopSize（251）只放行给持有租约的人。和 README 不同。** README 列的可发消息里没有这两个。Xvnc 带 `-AcceptSetDesktopSize`，所以持有者确实能改助手的分辨率；我们照 README 不发。noVNC 在 Xvnc 宣告 QEMU 扩展键盘后会改用 255 发按键；我们不声明它，只用 KeyEvent。
10. **1001 也算正常关闭。** 桥把 1000 和 1001 都当成「viewer 主动关了」，持有者这样关都会交还租约。App 退出时发 1001 也一样交还。
11. **`display.*` 每次都要带 `profile`。** 不带的话，gateway 回答的是启动它的那个 profile 的屏幕（官方桌面端踩过这个坑）。租约广播里不带 `viewer_id`，只带 `viewer_hash`，是 `viewer_id` 的 SHA-256 的前 12 个十六进制字符，用它认出持有者是不是自己。官方桌面端被 4000 挤掉后会自动换新 ticket 回到只看，但连上后不到 10 秒就又被挤掉、连续超过 3 次时就停下，显示错误和「重新连接」，免得两个窗口互相抢。
12. **接管期间缩略图是空的。** 有人持有租约时，`display.thumbnail` 返回 `data_url: null` 和 `suppressed`，因为画面上可能有正在输入的密码。缩略图和侧栏预览要处理这种情况。
13. **Origin。** 桥只在请求带了 `http(s)` 的 Origin 时检查它是不是网关自己的域名，没有 Origin 就放行。`NWWebSocketTransport` 和 `URLSessionWebSocketTask` 默认都不加 Origin 头，应该没问题，还没在真服务器上确认。
14. **桥会把 ClientInit 的共享标志强制改成 1**，Xvnc 也带 `-AlwaysShared`，所以不会因为我们连上去把助手或别人挤掉。
15. **在 macOS 上，服务器主动关闭时的关闭码：URLSession 要一直挂着 receive 才拿得到，Network.framework 拿不到。** CI 的 macOS 上，用 `replay_server.py` 放完录像后用 4000 关闭。最早的版本（不挂着 receive，发送一失败客户端就结束）：
    - `URLSessionWebSocketTask`：读和写都只报 `ENOTCONN`（Socket is not connected），任务结束时 `closeCode` 还是 0，`didCloseWith` 根本没被调用。我们自己关闭时它能正确发出 1000、也能收到对方的 1000。升级被拒（403）时报 `-1011`，状态码从 `task.response` 能拿到。
    - Network.framework（`NWConnection` + `NWProtocolWebSocket`）：我们自己关闭时能收到服务器回的关闭帧和 1000；这一次 4000 没拿到：客户端正在回一个 Fence，发送先失败了，当时的客户端一遇到发送失败就结束，没去读排在后面的关闭帧。升级被拒时它不给 HTTP 状态，只进入 `waiting(ECONNABORTED)`，所以加了连接超时，`waiting` 也当连不上。
    - 改了两处：客户端自己回的消息发送失败时继续读，直到传输层报出关闭原因（最多再等 2 秒）；两个 Apple 传输都一直挂着一个 receive（收到的放进有上限的队列，超过 8 MiB 先停收），关闭帧一到就读进来，不用等客户端来读。Linux 上用自带的客户端和一个「写坏了、读还在」的测试传输验证过。
    - 改完之后再在 macOS 上跑（bad287b）：**URLSession 拿到了 4000**。`didCloseWith 4000` 被调用，`run` 以关闭码 4000 结束，关闭前的 7 帧一帧不少。**Network.framework 还是没有**：连接直接 `ready → failed(ENOTCONN)`，一直挂着的那个 receive 收到的是这个错误，服务器的关闭帧始终没交上来。我们自己关闭时，它倒是能收到服务器回的关闭帧。所以 URLSession 的问题出在当时没有挂着 receive，Network.framework 的问题在它自己。
    - 所以 App 用 `URLSessionWebSocketTransport`（它一直挂着 receive），并且不只靠关闭码：没有关闭码时看租约（见「用法」）。官方桌面端用浏览器的 WebSocket，能拿到 4000，不受这个影响。
16. **空闲的桌面什么都不发，要自己保活。** 开着连续更新时，画面不变 Xvnc 就一个字节也不发，断掉的连接在读的一侧看不出来。Xvnc 会立刻原样回客户端发的 Fence 请求（经过 Hermes 的过滤器实测，静止的画面 5 秒回了 5 次），所以 keepalive 用 Fence 做：不依赖传输层，还能顺带确认 Xvnc 本身活着，而不只是桥。把 testbed 的 Xvnc 用 SIGSTOP 冻住，客户端在超时后报 `timedOut`，而不是一直等。

## 下一步

### macOS 显示层

- 一个 layer-backed 的 `NSView`。按服务器尺寸建一块 BGRA 的 IOSurface（格式和帧缓冲一样，直接逐行拷）。在 `run` 的回调里只拷脏矩形，拷完通知主线程刷新 `CALayer` 的 `contents`。解码和拷贝都不在主线程。
- 等比缩放，`contentsGravity = .resizeAspect`；收到 `.resized` 换一块 IOSurface。窗口大小只影响本地缩放，不发 SetDesktopSize。
- 连接管理：只看时窗口不可见就关（取消 task 即可）；4000（或租约显示别人接管了）换新 ticket 回到只看（照官方，限制连续被挤掉的次数）；4401 重新 `display.observe`；4001 或服务器自己的 1000 先查 `display.status`；只断了画面连接时自动重连，带上原来的 `viewer_id`（同一条 gateway 连接上才有效）；gateway 连接也断了就用新 id 重新接管。

### 接管

- `display.lease.acquire` / `release` 带 `viewer_id`（同一条 gateway 连接发的），用 `viewer_hash` 认出自己是不是持有者。
- 鼠标：本地坐标按缩放比例换回远端像素，`post(.pointer…)`；滚轮用 `post(.scroll…)`，触控板的连续滚动要攒到一格再发。接管那一下点击不发。
- 打开 Cursor 伪编码，按第 8 条处理空光标。
- 键盘：字符换成 X keysym，功能键按键码映射，⌘ 当 Ctrl 发；⌘Tab、⌘Q 留给 Mac。RoyalVNCKit（MIT）的键位表可以参考，照许可保留版权声明。
- ⌘V：`post(.paste(text, …))`，先查 `clipboardFits`。⌘C 取回在 Hermes 改动之前做不到（第 1 条）。

### 输入法

照 README：画面视图实现 `NSTextInputClient`，拼写中的文字显示在你最后点的位置；确认后的文字走 `post(.paste…)`（剪贴板 + Ctrl+V），不碰 Mac 自己的剪贴板。英文、数字、快捷键照常按键发。

### 带宽

先用 `rfb-probe` 在真的线路上量。不够的话再做 Tight + JPEG（JPEG 用系统的 ImageIO 解）。

### App 怎么接上

`macos/project.yml`（XcodeGen）里加本地包，target 依赖两个 product：

```yaml
packages:
  RFB:
    path: ../rfb
targets:
  Shion:
    dependencies:
      - package: RFB
        product: RFB
      - package: RFB
        product: RFBNetwork
```

- ticket 由 App 现有的 gateway 连接调 `display.observe` 拿（带 `profile`），WebSocket 地址用同一个网关的域名加返回的 `path`；Access 的两个头从钥匙串取，放进给 `URLSessionWebSocketTransport` 的 `URLRequest`（App 的 `ServerSettings.applyAccessHeaders(to:)` 正好能用）。
- 连接意外断开时，用 gateway 连接上的 `display.lease` 判断是被挤掉还是网络断了（第 15 条）。`viewer_id` 跟着 gateway 连接走（见「用法」）。
- SwiftUI 里把 `run` 放进画面视图的 `.task`：视图消失时 task 被取消，客户端用 1000 关闭、桥交还租约。输入事件一律 `post`。
- App 默认 MainActor 隔离。`run` 的回调在客户端的 actor 上跑，回调里只碰线程安全的东西（IOSurface），要更新界面再切回主线程。
- 以后搬到单独的仓库：`git subtree split --prefix=rfb -b rfb-split`，推到新仓库，App 改用 `.package(url:)`。包里的东西都自成一体，不用改。

## 还没验证

- 真服务器：经 Cloudflare Tunnel + Access 的 `wss://`（URLSession 走 TLS 加两个请求头）、真实的带宽和延迟、VPS 上的 TigerVNC 版本。`rfb-probe --gateway` 的 `/api/ws` JSON-RPC 调用是照源码写的，没在真的网关上跑过。
- Network.framework 为什么交不出服务器主动发的关闭帧（第 15 条）。App 不用它，所以不急。
- `URLSessionWebSocketTask.cancel()`（`.abort` 用它）会不会仍然发关闭帧；Network.framework 用的是 `forceCancel()`。
- keepalive 的默认值（15 秒发一次、15 秒没回算断）是拍的，要看真线路上的情况再调。
