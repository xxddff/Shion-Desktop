import AppKit
import QuickLook
import SwiftUI

extension EnvironmentValues {
    /// The assistant whose chat a view is in: the chat's files are in its profile.
    @Entry var chatBotId: String = ""
}

/// Your message: its pictures, its files, then the words in the bubble.
struct UserMessage: View {
    let item: ChatItem

    var body: some View {
        let pictures = item.media.filter { $0.kind == .image }
        let files = item.media.filter { $0.kind != .image }
        HStack {
            Spacer(minLength: 80)
            VStack(alignment: .trailing, spacing: 6) {
                if !pictures.isEmpty {
                    SentPictures(pictures: pictures)
                }
                ForEach(files) { file in
                    FileCard(media: file)
                }
                if !item.text.isEmpty || item.media.isEmpty {
                    Text(item.text)
                        .font(.t13)
                        .foregroundStyle(Palette.onAccent)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Palette.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
    }
}

/// The pictures you sent: one up to 320 points; two to four in two columns; more fold into 「+N」.
struct SentPictures: View {
    @Environment(AppStore.self) private var store
    @Environment(\.chatBotId) private var botId
    let pictures: [ChatMedia]
    @State private var previews: [URL] = []
    @State private var previewing: URL?

    var body: some View {
        Group {
            if pictures.count == 1 {
                MediaPicture(media: pictures[0], box: CGSize(width: 320, height: 320), keep: true, identifier: "sent-picture") {
                    open(0)
                }
            } else {
                let shown = pictures.count > 4 ? Array(pictures.prefix(3)) : pictures
                LazyVGrid(columns: [GridItem(.fixed(150), spacing: 4), GridItem(.fixed(150), spacing: 4)], spacing: 4) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, picture in
                        MediaPicture(media: picture, box: CGSize(width: 150, height: 150), tile: true, keep: true,
                                     identifier: "sent-picture") {
                            open(index)
                        }
                    }
                    if pictures.count > 4 {
                        Button {
                            open(3)
                        } label: {
                            Text(verbatim: "+\(pictures.count - 3)")
                                .font(.t15)
                                .foregroundStyle(.secondary)
                                .frame(width: 150, height: 150)
                                .background(Palette.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 304)
            }
        }
        .quickLookPreview($previewing, in: previews)
    }

    /// Quick Look on the message's pictures the Mac has, at the one clicked.
    private func open(_ index: Int) {
        Task {
            var urls: [URL] = []
            var selected: URL?
            for (position, picture) in pictures.enumerated() {
                guard let url = await store.previewURL(picture, botId: botId) else { continue }
                urls.append(url)
                if position == index || selected == nil && position > index {
                    selected = url
                }
            }
            guard !urls.isEmpty else { return }
            previews = urls
            previewing = selected ?? urls.first
        }
    }
}

/// What a reply hands over, under its words: pictures as wide as the words and at most 480
/// points high, with their alt text under them; other files as cards.
struct DeliveredMedia: View {
    @Environment(AppStore.self) private var store
    @Environment(\.chatBotId) private var botId
    let media: [ChatMedia]
    @State private var previewing: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(media) { item in
                if item.kind == .image {
                    VStack(alignment: .leading, spacing: 4) {
                        MediaPicture(media: item, box: CGSize(width: 560, height: 480), quietWhenGone: item.unconfirmed,
                                     identifier: "reply-picture") {
                            Task { previewing = await store.previewURL(item, botId: botId) }
                        }
                        if let caption = item.caption {
                            Text(caption)
                                .font(.t12)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    FileCard(media: item)
                }
            }
        }
        .quickLookPreview($previewing)
    }
}

/// A tool call's line, with the pictures it made or looked at under it.
struct ToolCall: View {
    @Environment(AppStore.self) private var store
    @Environment(\.chatBotId) private var botId
    let item: ChatItem

    var body: some View {
        let paths = store.toolShots(botId, item.id)
        if paths.isEmpty {
            ToolLine(text: item.text)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ToolLine(text: item.text)
                ToolShotRow(paths: paths)
                    .padding(.leading, 18)
            }
        }
    }
}

/// A folded run's pictures, small, under its line.
struct RunShots: View {
    @Environment(AppStore.self) private var store
    @Environment(\.chatBotId) private var botId
    let tools: [ChatItem]

    var body: some View {
        let paths = tools.flatMap { store.toolShots(botId, $0.id) }
        if !paths.isEmpty {
            ToolShotRow(paths: paths, height: 40)
                .padding(.leading, 18)
        }
    }
}

struct ToolShotRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.chatBotId) private var botId
    let paths: [String]
    var height: CGFloat = 56
    @State private var previewing: URL?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(paths, id: \.self) { path in
                let shot = ChatMedia(serverPath: path)
                MediaPicture(media: shot, box: CGSize(width: height * 1.8, height: height), cached: AppStore.shotPixels,
                             identifier: "tool-shot") {
                    Task { previewing = await store.previewURL(shot, botId: botId) }
                }
            }
        }
        .quickLookPreview($previewing)
    }
}

/// One of the chat's pictures, at most `box` and never past its own size: a light grey block
/// while it loads (no spinner), then the picture, which a click opens in Quick Look. A web
/// picture waits for 「显示图片」; one the server and the Mac no longer have says so.
struct MediaPicture: View {
    @Environment(AppStore.self) private var store
    @Environment(\.chatBotId) private var botId
    @Environment(\.displayScale) private var scale
    let media: ChatMedia
    var box: CGSize
    /// A square tile, cropped to fill it.
    var tile = false
    /// One you sent: the Mac keeps it past the cache's limit.
    var keep = false
    /// Nothing at all when it cannot be had: a path a reply only mentioned.
    var quietWhenGone = false
    /// Decoded at this many pixels instead of the box's (to share a picture fetched ahead).
    var cached: Int?
    var identifier = "chat-picture"
    var open: (() -> Void)?
    @State private var load: AppStore.PictureLoad?
    @State private var asked = false
    @State private var attempt = 0

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .task(id: "\(media.id)|\(asked)|\(attempt)|\(store.live)") {
            load = await store.loadPicture(media, botId: botId, maxPixel: cached ?? pixels, keep: keep, web: asked)
        }
    }

    private var pixels: Int {
        Int((max(box.width, box.height) * max(scale, 1)).rounded(.up))
    }

    @ViewBuilder
    private var content: some View {
        switch load {
        case .shown(let picture)?:
            let size = tile ? box : Self.fitted(picture.pixels, in: box, scale: scale)
            Image(decorative: picture.image, scale: max(scale, 1))
                .resizable()
                .aspectRatio(contentMode: tile ? .fill : .fit)
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.line.opacity(0.5)))
                .contentShape(Rectangle())
                .onTapGesture { open?() }
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isImage)
                .accessibilityLabel(media.caption ?? AppStore.displayName(media.name))
                .accessibilityValue("已显示")
                .accessibilityAction { open?() }
                .accessibilityIdentifier(identifier)
        case .waiting?:
            VStack(spacing: 6) {
                Image(systemName: "photo")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(media.url?.host ?? "")
                    .font(.t12)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("显示图片") { asked = true }
                    .controlSize(.small)
                    .accessibilityIdentifier("show-web-picture")
            }
            .frame(width: placeholder.width, height: placeholder.height)
            .background(Palette.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(media.caption ?? "网上的图片")
            .accessibilityValue("点了才显示")
            .accessibilityIdentifier("web-picture")
        case .gone?:
            if !quietWhenGone {
                block("图片已过期", value: "已过期")
            }
        case .failed(let reason)?:
            if !quietWhenGone {
                block("图片没取到", value: "没取到")
                    .help(reason)
                    .onTapGesture { attempt += 1 }
            }
        case nil:
            block(nil, value: "加载中")
        }
    }

    private var placeholder: CGSize {
        tile ? box : CGSize(width: min(box.width, 240), height: min(box.height, (min(box.width, 240) * 0.66).rounded()))
    }

    private func block(_ words: String?, value: String) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Palette.fill)
            .frame(width: placeholder.width, height: placeholder.height)
            .overlay {
                if let words {
                    Text(words)
                        .font(.t12)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(media.caption ?? AppStore.displayName(media.name))
            .accessibilityValue(value)
            .accessibilityIdentifier(identifier)
    }

    /// The picture's own size on this screen, brought into `box`.
    static func fitted(_ pixels: CGSize, in box: CGSize, scale: CGFloat) -> CGSize {
        let natural = CGSize(width: pixels.width / max(scale, 1), height: pixels.height / max(scale, 1))
        let factor = min(1, box.width / max(natural.width, 1), box.height / max(natural.height, 1))
        return CGSize(width: max(1, (natural.width * factor).rounded()), height: max(1, (natural.height * factor).rounded()))
    }
}

/// A file in the chat: its kind, name and size. A click saves it to Downloads and opens it; with
/// ⌥ held it is only saved. One a reply only mentioned shows once the server says it is there.
struct FileCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.chatBotId) private var botId
    let media: ChatMedia
    @State private var check: AppStore.FileCheck?
    @State private var busy = false
    @State private var problem: String?
    @State private var previewing: URL?

    var body: some View {
        VStack(spacing: 0) {
            if !media.unconfirmed || present {
                card
            }
        }
        .task(id: "\(media.id)|\(store.live)") {
            check = await store.checkFile(media, botId: botId)
        }
    }

    private var present: Bool {
        if case .present? = check { return true }
        return false
    }

    private var name: String { AppStore.displayName(media.name) }

    private var saved: Bool { store.media.saved[media.id] != nil }

    private var card: some View {
        Button {
            save(open: !NSEvent.modifierFlags.contains(.option))
        } label: {
            HStack(spacing: 10) {
                Image(systemName: Self.symbol(media))
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.t13)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(detail)
                        .font(.t12)
                        .foregroundStyle(problem == nil ? Color.secondary : Palette.alert)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if busy {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(width: 280, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(media.kind == .folder || busy)
        .contextMenu {
            if media.kind != .folder {
                Button("存到「下载」") { save(open: false) }
                Button("在访达中显示") { reveal() }
                Button("快速查看") {
                    Task { previewing = await store.previewURL(media, botId: botId) }
                }
            }
            if let path = media.path {
                Button("拷贝服务器上的路径") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                }
            }
        }
        .quickLookPreview($previewing)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(name)
        .accessibilityValue(saved ? "已下载" : detail)
        .accessibilityIdentifier("file-card")
    }

    private var detail: String {
        if busy { return "正在下载…" }
        if let problem { return problem }
        if saved { return "已存到「下载」" }
        if check == .gone { return "服务器上已经没有了" }
        if media.kind == .folder { return "文件夹" }
        var parts = [MediaKinds.fileExtension(media.name).uppercased()].filter { !$0.isEmpty }
        if case .present(let size?)? = check {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        } else if let size = media.size, size > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        return parts.isEmpty ? "文件" : parts.joined(separator: " · ")
    }

    private func save(open: Bool) {
        busy = true
        problem = nil
        Task {
            defer { busy = false }
            do {
                try await store.saveFile(media, botId: botId, open: open)
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func reveal() {
        busy = true
        problem = nil
        Task {
            defer { busy = false }
            do {
                try await store.revealFile(media, botId: botId)
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    static func symbol(_ media: ChatMedia) -> String {
        if media.kind == .folder { return "folder" }
        switch MediaKinds.fileExtension(media.name) {
        case "pdf": return "doc.richtext"
        case "png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff", "heic", "heif", "svg": return "photo"
        case "mp3", "m4a", "wav", "ogg", "opus", "flac", "m2a": return "waveform"
        case "mp4", "mov", "avi", "mkv", "webm", "3gp": return "film"
        case "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar": return "doc.zipper"
        case "xlsx", "xls", "ods", "csv", "tsv": return "tablecells"
        case "pptx", "ppt", "odp", "key": return "rectangle.on.rectangle"
        case "txt", "md", "json", "xml", "yaml", "yml", "html", "htm", "rtf": return "doc.text"
        default: return "doc"
        }
    }
}
