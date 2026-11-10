import Foundation
import Observation

/// One thing in a composer before it is sent. Its bytes are in the Mac's cache (`sha256`); the
/// upload makes it a path on the server, and a file also an `@file:` reference.
struct Draft: Identifiable, Equatable {
    enum Stage: Equatable {
        /// Being read, made ready or uploaded; the share gone out, when known.
        case uploading(Double?)
        case ready
        case failed(String, retry: Bool)
    }

    let id: UUID
    var kind: ChatMedia.Kind
    var name: String
    var size: Int
    var mime: String
    var sha256: String?
    var stage = Stage.uploading(nil)
    /// On the server: a picture in `cache/images/`, a file in `attachments/`.
    var path: String?
    /// A file's reference, `@file:<path>`, which the message's words start with.
    var ref: String?
    /// The reference's own path, relative to the session's directory when the file is in it.
    var refPath: String?

    var isReady: Bool { stage == .ready }

    /// As the sent message shows it.
    var media: ChatMedia {
        ChatMedia(kind: kind, name: name, path: path, sha256: sha256, size: size)
    }
}

/// Pictures and files in the chats: what each composer is about to send, the pictures tool calls
/// made, what you saved, and the decoded pictures on screen. The bytes are in `disk`.
@Observable
final class MediaStore {
    /// bot id → its composer's attachments, in the order added.
    private(set) var drafts: [String: [Draft]] = [:]
    /// `bot|tool item id` → the server paths of the pictures that tool call made or looked at.
    private(set) var toolShots: [String: [String]]
    /// Source key → where you saved the file.
    private(set) var saved: [String: URL] = [:]
    private(set) var usage = MediaIndex.Usage(fetched: 0, kept: 0)
    /// Bring a picture's long edge down to 2048 before sending it.
    private(set) var shrinkPictures: Bool
    /// Show the web's pictures in replies without a click.
    private(set) var showWebPictures: Bool

    let disk: MediaDisk
    private let snapshot: Bool
    /// Decoded pictures, by what they are and how big they were decoded.
    private let decoded = NSCache<NSString, PictureObject>()
    @ObservationIgnored var uploads: [UUID: Task<Void, Never>] = [:]
    /// Tool rows whose pictures were looked up on disk already.
    @ObservationIgnored var lookedUp: Set<String> = []
    /// Pictures being fetched, by what they are: one fetch however many rows ask.
    @ObservationIgnored var fetches: [String: Task<AppStore.PictureBytes, Never>] = [:]

    init(snapshot: Bool = LaunchOptions.current.snapshot) {
        self.snapshot = snapshot
        disk = MediaDisk(folder: MediaDisk.location(snapshot: snapshot))
        let defaults = UserDefaults.standard
        shrinkPictures = snapshot ? true : defaults.object(forKey: "MediaShrinkPictures") as? Bool ?? true
        showWebPictures = snapshot ? false : defaults.bool(forKey: "MediaShowWebPictures")
        decoded.countLimit = 300
        // the demo's mail assistant looked at the inbox (DemoData's mail chat)
        toolShots = ["mail|x6": ["/opt/data/profiles/mail/cache/screenshots/收件箱.png"]]
        if snapshot && defaults.bool(forKey: "ShionDemoDrafts") {
            drafts["mail"] = Self.demoDrafts
        }
    }

    // MARK: preferences

    func setShrinkPictures(_ on: Bool) {
        shrinkPictures = on
        if !snapshot {
            UserDefaults.standard.set(on, forKey: "MediaShrinkPictures")
        }
    }

    func setShowWebPictures(_ on: Bool) {
        showWebPictures = on
        if !snapshot {
            UserDefaults.standard.set(on, forKey: "MediaShowWebPictures")
        }
    }

    // MARK: drafts

    func draft(_ id: UUID, in botId: String) -> Draft? {
        drafts[botId]?.first { $0.id == id }
    }

    func add(_ draft: Draft, to botId: String) {
        drafts[botId, default: []].append(draft)
    }

    func update(_ id: UUID, in botId: String, _ change: (inout Draft) -> Void) {
        guard let index = drafts[botId]?.firstIndex(where: { $0.id == id }) else { return }
        change(&drafts[botId]![index])
    }

    /// How far an upload is; only while it is under way.
    func progress(_ id: UUID, in botId: String, _ share: Double) {
        update(id, in: botId) { draft in
            if case .uploading = draft.stage {
                draft.stage = .uploading(share)
            }
        }
    }

    func remove(_ id: UUID, from botId: String) {
        uploads.removeValue(forKey: id)?.cancel()
        drafts[botId]?.removeAll { $0.id == id }
        if drafts[botId]?.isEmpty == true {
            drafts[botId] = nil
        }
    }

    /// The composer's attachments, which leave it with the message.
    func takeDrafts(_ botId: String) -> [Draft] {
        let taken = drafts[botId] ?? []
        drafts[botId] = nil
        return taken
    }

    // MARK: tool pictures

    func addShot(_ path: String, key: String) {
        guard toolShots[key]?.contains(path) != true else { return }
        toolShots[key, default: []].append(path)
    }

    func setShots(_ paths: [String], key: String) {
        toolShots[key] = paths
    }

    // MARK: saved files and the cache

    func markSaved(_ url: URL, key: String) {
        saved[key] = url
    }

    func refreshUsage() async {
        usage = await disk.usage()
    }

    func clear(keptToo: Bool) async {
        await disk.clear(keptToo: keptToo)
        decoded.removeAllObjects()
        saved = [:]
        await refreshUsage()
    }

    // MARK: decoded pictures

    func decodedPicture(_ key: String) -> Picture? {
        decoded.object(forKey: key as NSString)?.picture
    }

    func keepDecoded(_ picture: Picture, key: String) {
        decoded.setObject(PictureObject(picture), forKey: key as NSString)
    }

    /// What a screenshot run shows in the mail chat's composer: a picture and a file ready, one
    /// picture still going up, a file too big to send.
    private static let demoDrafts: [Draft] = [
        Draft(id: UUID(), kind: .image, name: "讲义.jpg", size: 412_000, mime: "image/jpeg", stage: .ready,
              path: "/opt/data/profiles/mail/cache/images/讲义.jpg"),
        Draft(id: UUID(), kind: .file, name: "实验数据.csv", size: 12_800, mime: "text/csv", stage: .ready),
        Draft(id: UUID(), kind: .image, name: "提交页面.png", size: 268_000, mime: "image/png", stage: .uploading(0.4),
              path: "/opt/data/profiles/mail/cache/images/提交页面.png"),
        Draft(id: UUID(), kind: .file, name: "第7回录音.m4a", size: 48_300_000, mime: "audio/mp4",
              stage: .failed("文件超过 16 MB，发不了", retry: false)),
    ]
}

/// NSCache holds objects.
final class PictureObject {
    let picture: Picture

    init(_ picture: Picture) {
        self.picture = picture
    }
}
