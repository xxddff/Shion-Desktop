import SwiftUI

/// Settings › 图片和文件: what a sent picture loses, when the web's pictures are fetched, and the
/// Mac's copies. The chat itself says none of this.
struct MediaSettings: View {
    @Environment(AppStore.self) private var store
    @State private var confirmingAll = false

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { store.media.shrinkPictures }, set: { store.media.setShrinkPictures($0) })) {
                Text("发图前缩小")
                Text("长边超过 2048 像素的缩到 2048，视觉模型自己也会缩，大图只多花流量。HEIC、TIFF、BMP 转成 JPEG，带透明的转成 PNG，GIF 原样发。发出去的照片不带位置，也不带拍摄时间和相机型号。")
            }
            Toggle(isOn: Binding(get: { store.media.showWebPictures }, set: { store.media.setShowWebPictures($0) })) {
                Text("直接显示网上的图片")
                Text("关着时，回复里网上的图片先是一块占位，写着网站名，点「显示图片」才去取：去取时，那个网站会知道你的 IP 和看的时间。取的时候不带 Cookie、不发来源页，只收图片，最多 20 MB；本机和局域网里的地址一律不取。")
            }
            LabeledContent("Mac 上的副本") {
                Text(usage)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("media-cache")
            }
            .task {
                await store.media.refreshUsage()
            }
            // a row of their own: beside the sizes they left no room for them in a narrow window
            HStack(spacing: 8) {
                Spacer()
                Button("清除取回的") {
                    Task { await store.media.clear(keptToo: false) }
                }
                Button("全部清除…") {
                    confirmingAll = true
                }
            }
        } header: {
            Text("图片和文件")
        } footer: {
            Text("你发的图，服务器上只留一天左右，Mac 上一直留着一份，清除取回的文件时不删。截图、助手交来的图片和文件，取过一次也留在 Mac 上，超过 1 GB 先删最久没看的。服务器上的过期了，对话里照样显示 Mac 上的这份。退出登录、换服务器时都不删：按服务器和助手分开记，不会串，要删用上面的按钮。一个文件最多 16 MB，一张图 25 MB，一条消息最多 10 张图。")
                .font(.t12)
                .foregroundStyle(.secondary)
        }
        .confirmationDialog("连你发出去的图也删掉？", isPresented: $confirmingAll) {
            Button("全部清除", role: .destructive) {
                Task { await store.media.clear(keptToo: true) }
            }
        } message: {
            Text("服务器上一天以前的图已经没有了，删掉后，这些对话里只剩「图片已过期」。")
        }
    }

    private var usage: String {
        let fetched = ByteCountFormatter.string(fromByteCount: Int64(store.media.usage.fetched), countStyle: .file)
        let kept = ByteCountFormatter.string(fromByteCount: Int64(store.media.usage.kept), countStyle: .file)
        return "取回的 \(fetched) · 你发的 \(kept)"
    }
}
