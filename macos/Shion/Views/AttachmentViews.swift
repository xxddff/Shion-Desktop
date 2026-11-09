import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The composer with what it is about to send: the attachments above it, the 「＋」 on its left,
/// all floating over the transcript in one glass container.
struct ComposerBar<Field: View>: View {
    @Environment(AppStore.self) private var store
    let botId: String
    let field: Field

    init(botId: String, @ViewBuilder field: () -> Field) {
        self.botId = botId
        self.field = field()
    }

    var body: some View {
        let drafts = store.media.drafts[botId] ?? []
        GlassEffectContainer(spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                if !drafts.isEmpty {
                    AttachmentTray(botId: botId, drafts: drafts)
                }
                HStack(alignment: .bottom, spacing: 8) {
                    AttachButton(botId: botId)
                    field
                }
            }
        }
    }
}

/// 「＋」: pick pictures and files to send.
struct AttachButton: View {
    @Environment(AppStore.self) private var store
    let botId: String
    @State private var picking = false

    var body: some View {
        Button {
            picking = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .help("添加图片或文件")
        .accessibilityLabel("添加图片或文件")
        .accessibilityIdentifier("attach")
        .fileImporter(isPresented: $picking, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                store.attach(urls, to: botId)
            }
        }
    }
}

/// What the composer will send, in a row: pictures as thumbnails, files by name and size.
struct AttachmentTray: View {
    let botId: String
    let drafts: [Draft]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                ForEach(drafts) { draft in
                    DraftChip(botId: botId, draft: draft)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
        .scrollIndicators(.never)
        .defaultScrollAnchor(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .accessibilityIdentifier("attachment-tray")
    }
}

/// One attachment: a ring while it goes up, red with the reason on hover when it cannot (a click
/// tries again when trying again can help), and a × to take it out. To accessibility it is one
/// element, its name and where it is, with 移除 (and 再试一次) as its actions.
struct DraftChip: View {
    @Environment(AppStore.self) private var store
    let botId: String
    let draft: Draft

    var body: some View {
        face
            // alongside the thumbnail's own tap, which would otherwise take the click
            .simultaneousGesture(TapGesture().onEnded { _ in
                if retryable {
                    store.retryDraft(draft.id, in: botId)
                }
            })
            .overlay { stageOverlay }
            .overlay(alignment: .topTrailing) {
                Button {
                    store.removeDraft(draft.id, from: botId)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.white, Color.black.opacity(0.55))
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
            }
            .help(helpText)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(draft.name)
            .accessibilityValue(stateText)
            .accessibilityIdentifier(draft.kind == .image ? "draft-picture" : "draft-file")
            .accessibilityActions {
                if retryable {
                    Button("再试一次") { store.retryDraft(draft.id, in: botId) }
                }
                Button("移除") { store.removeDraft(draft.id, from: botId) }
            }
    }

    private var retryable: Bool {
        if case .failed(_, retry: true) = draft.stage { return true }
        return false
    }

    @ViewBuilder
    private var face: some View {
        if draft.kind == .image {
            if draft.sha256 != nil || draft.path != nil {
                MediaPicture(media: ChatMedia(kind: .image, name: draft.name, path: draft.path, sha256: draft.sha256),
                             box: CGSize(width: 56, height: 56), tile: true, identifier: "draft-thumbnail")
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Palette.fill)
                    .frame(width: 56, height: 56)
            }
        } else {
            HStack(spacing: 8) {
                Image(systemName: FileCard.symbol(draft.media))
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.name)
                        .font(.t12)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(draft.size > 0 ? ByteCountFormatter.string(fromByteCount: Int64(draft.size), countStyle: .file) : " ")
                        .font(.t11)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(width: 168, height: 56, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.line))
        }
    }

    @ViewBuilder
    private var stageOverlay: some View {
        switch draft.stage {
        case .uploading(let share):
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.32))
                if let share {
                    ProgressView(value: share)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .allowsHitTesting(false)
        case .failed:
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Palette.alert, lineWidth: 2)
                .overlay(alignment: .bottomLeading) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 13))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.white, Palette.alert)
                        .padding(4)
                }
                .allowsHitTesting(false)
        case .ready:
            EmptyView()
        }
    }

    private var helpText: String {
        switch draft.stage {
        case .uploading: return "正在上传 \(draft.name)"
        case .ready: return draft.name
        case .failed(let reason, let retry): return retry ? "\(reason)。点一下再试" : reason
        }
    }

    private var stateText: String {
        switch draft.stage {
        case .uploading: return "上传中"
        case .ready: return "已就绪"
        case .failed(let reason, _): return "没传上去：\(reason)"
        }
    }
}

extension View {
    /// Pictures and files dropped on the chat or pasted with ⌘V go into its composer; the tool
    /// rows' pictures the Mac remembers are looked up as rows arrive.
    func chatAttachments(_ botId: String) -> some View {
        modifier(ChatAttachments(botId: botId))
    }
}

struct ChatAttachments: ViewModifier {
    @Environment(AppStore.self) private var store
    let botId: String
    @State private var targeted = false
    @State private var monitor: Any?
    @State private var window: Int?

    func body(content: Content) -> some View {
        let tools = (store.chats[botId] ?? []).filter { $0.role == .tool }.map(\.id)
        return content
            .onDrop(of: [.fileURL, .image], isTargeted: $targeted) { providers in
                take(providers)
            }
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Palette.accent, lineWidth: 2)
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .background(WindowNumber { window = $0 })
            .onAppear(perform: watchPaste)
            .onDisappear(perform: stopWatching)
            .task(id: tools.count) {
                await store.lookUpToolShots(botId, tools)
            }
    }

    private func take(_ providers: [NSItemProvider]) -> Bool {
        let store = store
        let botId = botId
        var taken = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                taken = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in store.attach([url], to: botId) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                taken = true
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in store.attach(pictureData: data, name: "拖进来的图片", to: botId) }
                }
            }
        }
        return taken
    }

    /// ⌘V in this chat's window: files copied in Finder, or a picture with no words to paste,
    /// go to the composer; anything else pastes as it always does.
    private func watchPaste() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "v",
                  let window, event.windowNumber == window,
                  paste()
            else { return event }
            return nil
        }
    }

    private func stopWatching() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    private func paste() -> Bool {
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            store.attach(urls, to: botId)
            return true
        }
        // words paste into the field; a copied web picture often comes with its address only
        if let words = board.string(forType: .string), !(words.hasPrefix("http") && !words.contains(where: \.isWhitespace)) {
            return false
        }
        // the picture as it was put there, not a copy the pasteboard converts on the way
        let preferred = ["public.jpeg", "public.png", "public.heic", "org.webmproject.webp", "com.compuserve.gif", "public.tiff"]
        for item in board.pasteboardItems ?? [] {
            let types = Set(item.types.map(\.rawValue))
            for type in preferred where types.contains(type) {
                if let data = item.data(forType: NSPasteboard.PasteboardType(type)) {
                    store.attach(pictureData: data, name: "粘贴的图片", to: botId)
                    return true
                }
            }
        }
        return false
    }
}

/// Reports the number of the window the view is in.
private struct WindowNumber: NSViewRepresentable {
    let found: @MainActor (Int) -> Void

    func makeNSView(context: Context) -> Probe {
        Probe(found: found)
    }

    func updateNSView(_ view: Probe, context: Context) {}

    final class Probe: NSView {
        let found: @MainActor (Int) -> Void

        init(found: @escaping @MainActor (Int) -> Void) {
            self.found = found
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            return nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let number = window?.windowNumber else { return }
            let found = found
            // not while SwiftUI lays the view out
            Task { @MainActor in found(number) }
        }
    }
}
