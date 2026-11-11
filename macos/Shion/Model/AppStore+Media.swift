import AppKit
import UniformTypeIdentifiers

/// Pictures and files in the chats (docs/files-and-images.md, step 1), with the server as it is:
/// a picture goes up with `/api/chat/image-upload` and rides `prompt.submit`'s `attachments`; a
/// file becomes an `@file:` reference through `file.attach`, which the message's words start
/// with; the chat's pictures and files are read back with `/api/fs/*` (MediaClient.swift). What
/// is fetched stays on the Mac (MediaDisk.swift): Hermes clears most of it after about a day.
extension AppStore {
    /// Files up to this size go to `file.attach` as their bytes, which keeps their names; a bigger
    /// one is staged on the Webapp first, with progress and off the chat's socket, though Hermes
    /// then names it in ASCII (`hermes_cli/staged_uploads.py`).
    static let inlineFileLimit = 2 * 1024 * 1024
    /// Hermes takes 10 pictures per message.
    static let picturesPerMessage = 10
    /// How big a tool's picture is decoded, in the chat and when it is fetched ahead.
    static let shotPixels = 240

    // MARK: where things are

    /// The cache's key for a file on the server: which server, which assistant, which path; a
    /// relative path is in its session's directory.
    func sourceKey(_ path: String, botId: String) -> String {
        let session = path.hasPrefix("/") || path.hasPrefix("~") ? "" : sessions[botId] ?? ""
        return [serverSettings.signInServer, botId, session, path].joined(separator: "|")
    }

    /// A picture's or file's key in the Mac's memory (decoded, being fetched, saved): its
    /// server and assistant too, since two chats' relative paths can read the same.
    func mediaKey(_ item: ChatMedia, botId: String) -> String {
        item.path.map { sourceKey($0, botId: botId) } ?? item.id
    }

    private func shotKey(_ botId: String, _ itemId: String) -> String {
        [serverSettings.signInServer, botId, itemId].joined(separator: "|")
    }

    private var mediaClient: MediaClient? {
        gateway.credential.map { MediaClient(settings: serverSettings, credential: $0) }
    }

    /// A file's name as you gave it: a file staged on the Webapp is kept as `web-<16 hex>-<name>`.
    static func displayName(_ name: String) -> String {
        guard name.hasPrefix("web-"), let dash = name.dropFirst(4).firstIndex(of: "-") else { return name }
        let random = name[name.index(name.startIndex, offsetBy: 4)..<dash]
        guard random.count == 16, random.allSatisfy(\.isHexDigit) else { return name }
        let rest = name[name.index(after: dash)...]
        return rest.isEmpty ? name : String(rest)
    }

    // MARK: the composer

    nonisolated enum Incoming: Sendable {
        case file(URL)
        case bytes(Data, name: String)
    }

    /// Files dropped, picked or pasted: pictures by their names, the rest files.
    func attach(_ urls: [URL], to botId: String) {
        for url in urls {
            let name = url.lastPathComponent
            add(.file(url), kind: MediaKinds.isImage(name) ? .image : .file, name: name, to: botId)
        }
    }

    /// A picture pasted or dropped as bytes.
    func attach(pictureData data: Data, name: String, to botId: String) {
        add(.bytes(data, name: name), kind: .image, name: name, to: botId)
    }

    private func add(_ incoming: Incoming, kind: ChatMedia.Kind, name: String, to botId: String) {
        let id = UUID()
        media.add(Draft(id: id, kind: kind, name: name, size: 0, mime: ""), to: botId)
        media.uploads[id] = Task { await self.prepare(id, incoming, botId: botId) }
    }

    /// Reads and readies the bytes, keeps them in the cache, then uploads them.
    private func prepare(_ id: UUID, _ incoming: Incoming, botId: String) async {
        let shrink = media.shrinkPictures
        let picture = media.draft(id, in: botId)?.kind == .image
        do {
            let ready = try await Task.detached(priority: .userInitiated) {
                try Self.read(incoming, picture: picture, shrink: shrink)
            }.value
            guard media.draft(id, in: botId) != nil else { return }
            let hash = await media.disk.store(ready.data, name: ready.name)
            media.update(id, in: botId) { draft in
                draft.kind = ready.picture ? .image : .file
                draft.name = ready.name
                draft.size = ready.data.count
                draft.mime = ready.mime
                draft.sha256 = hash
            }
            let pictures = (media.drafts[botId] ?? []).filter { $0.kind == .image }
            if ready.picture, pictures.count > Self.picturesPerMessage, pictures.last?.id == id {
                media.update(id, in: botId) { $0.stage = .failed("一条消息最多 \(Self.picturesPerMessage) 张图", retry: false) }
                return
            }
            await upload(id, ready.data, botId: botId)
        } catch is CancellationError {
        } catch {
            media.update(id, in: botId) { $0.stage = .failed(error.localizedDescription, retry: false) }
        }
    }

    /// The bytes to send: a picture made ready (converted, brought down, without its metadata), a
    /// file as it is. A picture ImageIO cannot open goes as a file.
    private nonisolated static func read(_ incoming: Incoming, picture: Bool, shrink: Bool) throws
        -> (data: Data, name: String, mime: String, picture: Bool) {
        let data: Data
        let name: String
        switch incoming {
        case .file(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if values.isDirectory == true { throw MediaError.refused(0, "文件夹发不了") }
            let size = values.fileSize ?? 0
            // a picture is brought down first, so it may start bigger
            if size > (picture ? 4 * MediaClient.pictureLimit : MediaClient.fileLimit) {
                throw MediaError.tooLarge(picture ? "100 MB" : "16 MB")
            }
            data = try Data(contentsOf: url)
            name = url.lastPathComponent
        case .bytes(let bytes, let given):
            data = bytes
            name = given
        }
        if picture, let ready = Pictures.prepare(data, shrink: shrink) {
            guard ready.data.count <= MediaClient.pictureLimit else { throw MediaError.tooLarge("25 MB") }
            let stem = (name as NSString).deletingPathExtension
            return (ready.data, "\(stem.isEmpty ? "图片" : stem).\(ready.ext)", ready.mime, true)
        }
        guard data.count <= MediaClient.fileLimit else { throw MediaError.tooLarge("16 MB") }
        let type = UTType(filenameExtension: MediaKinds.fileExtension(name))
        return (data, name, type?.preferredMIMEType ?? "application/octet-stream", false)
    }

    /// Up to the server: a picture into the assistant's `cache/images/`, a file through
    /// `file.attach`. Without a server (the demo) it is ready at once.
    private func upload(_ id: UUID, _ data: Data, botId: String) async {
        guard let draft = media.draft(id, in: botId) else { return }
        guard live, let client = mediaClient else {
            media.update(id, in: botId) { $0.stage = .ready }
            return
        }
        media.update(id, in: botId) { $0.stage = .uploading(draft.kind == .image ? 0 : nil) }
        let store = media
        let progress: @Sendable (Double) -> Void = { share in
            Task { @MainActor in store.progress(id, in: botId, share) }
        }
        do {
            if draft.kind == .image {
                let path = try await client.uploadPicture(data, name: draft.name, mime: draft.mime, profile: botId,
                                                          progress: progress)
                media.update(id, in: botId) { draft in
                    draft.path = path
                    draft.stage = .ready
                }
                if let hash = draft.sha256 {
                    await media.disk.remember(sourceKey(path, botId: botId), hash: hash)
                }
            } else {
                let reply = try await attachFile(data, draft: draft, client: client, botId: botId, progress: progress)
                let path = reply["path"]?.string
                let refPath = reply["ref_path"]?.string
                guard let ref = reply["ref_text"]?.string ?? refPath.map({ "@file:" + $0 }) else { throw MediaError.badReply }
                media.update(id, in: botId) { draft in
                    draft.path = path ?? refPath
                    draft.ref = ref
                    draft.refPath = refPath
                    draft.stage = .ready
                }
                if let hash = draft.sha256 {
                    for known in [path, refPath].compactMap({ $0 }) {
                        await media.disk.remember(sourceKey(known, botId: botId), hash: hash)
                    }
                }
            }
        } catch is CancellationError {
        } catch {
            media.update(id, in: botId) { $0.stage = .failed(Self.uploadProblem(error), retry: true) }
        }
    }

    /// Why an upload did not go, in words: Hermes refuses with a reason code.
    private static func uploadProblem(_ error: Error) -> String {
        guard case GatewayError.rpc(_, let message, let reason) = error else { return error.localizedDescription }
        switch reason ?? message {
        case "storage_unavailable": return "服务器存不下"
        case "permission_denied": return "对话还没在这条连接上打开"
        case "invalid_params": return "服务器不收这个文件"
        default: return error.localizedDescription
        }
    }

    /// `file.attach {name, data_url}`; past `inlineFileLimit`, staged on the Webapp first and
    /// attached by its receipt (`staged_upload`). Never a `path`: Hermes would look for one on the
    /// server first.
    private func attachFile(_ data: Data, draft: Draft, client: MediaClient, botId: String,
                            progress: @escaping @Sendable (Double) -> Void) async throws -> JSONValue {
        guard let sessionId = sessions[botId] else { throw MediaError.chatClosed }
        var params: [String: JSONValue] = [
            "profile": .string(botId), "session_id": .string(sessionId), "name": .string(draft.name),
        ]
        if data.count > Self.inlineFileLimit,
           let receipt = try await client.uploadFile(data, name: draft.name, mime: draft.mime, profile: botId, progress: progress) {
            params["staged_upload"] = receipt
        } else {
            let mime = draft.mime
            let url = await Task.detached(priority: .userInitiated) { "data:\(mime);base64," + data.base64EncodedString() }.value
            params["data_url"] = .string(url)
        }
        // the bytes go at the line's speed: a big file gets its time
        return try await gateway.call("file.attach", .object(params), timeout: max(60, Double(data.count) / 50_000))
    }

    func retryDraft(_ id: UUID, in botId: String) {
        guard let draft = media.draft(id, in: botId), case .failed(_, retry: true) = draft.stage, let hash = draft.sha256 else { return }
        media.update(id, in: botId) { $0.stage = .uploading(nil) }
        media.uploads[id] = Task {
            guard let file = await media.disk.file(hash),
                  let data = await Task.detached(operation: { try? Data(contentsOf: file) }).value
            else {
                media.update(id, in: botId) { $0.stage = .failed("Mac 上的这份不在了，删掉重新加", retry: false) }
                return
            }
            await upload(id, data, botId: botId)
        }
    }

    func removeDraft(_ id: UUID, from botId: String) {
        media.remove(id, from: botId)
    }

    /// Once everything in the composer is up, and there are words or something to send.
    func canSend(_ botId: String, _ text: String) -> Bool {
        let drafts = media.drafts[botId] ?? []
        guard drafts.allSatisfy(\.isReady) else { return false }
        return !drafts.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Sends the words with what is in the composer; false when it is not all up yet.
    @discardableResult
    func sendMessage(_ text: String, to botId: String) -> Bool {
        guard media.drafts[botId]?.isEmpty == false else {
            send(text, to: botId)
            return true
        }
        guard !readOnly, canSend(botId, text) else { return false }
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard live else {
            let drafts = media.takeDrafts(botId)
            chats[botId, default: []].append(ChatItem(id: UUID().uuidString, role: .user, at: now, text: words,
                                                      media: drafts.map(\.media)))
            return true
        }
        guard let sessionId = sessions[botId] else { return false }
        let drafts = media.takeDrafts(botId)
        let mode = sendMode
        // the submission id names the item, as send's does: the turn's end says which row it was
        // stored as, which 重试 needs (AppStore+Control.swift)
        let id = UUID().uuidString
        chats[botId, default: []].append(ChatItem(id: id, role: .user, at: Date(), text: words,
                                                  media: drafts.map(\.media)))
        Task {
            // Hermes keeps a sent picture for about a day; the Mac keeps its own for good
            for hash in drafts.filter({ $0.kind == .image }).compactMap(\.sha256) {
                await media.disk.keep(hash)
            }
            await submit(words, drafts, botId: botId, sessionId: sessionId, submission: id, again: false, mode: mode)
        }
        return true
    }

    /// Whether 重试 may ask a prompt again. Not one that took pictures: Hermes keeps them as image
    /// parts of the stored row, which its own /retry will not replay and refuses before it rewinds
    /// anything ("no replay protocol": agent/context_compressor_retry.py, retryable_user_text,
    /// gateway/slash_commands_session.py); a rewind's receipt would hand back the words alone. The
    /// files of a prompt are `@file:` lines in its words, which a retry sends again as they were.
    static func retryable(_ prompt: ChatItem) -> Bool {
        !prompt.media.contains { $0.kind == .image }
    }

    /// The message as the official desktop words it: the files' references, one a line, a blank
    /// line, then your words; Hermes's own caption when only pictures go. Its receipt is followed
    /// as a message of words is (AppStore+Reconnect.swift): no answer before the connection went
    /// leaves it unsure until the server can say; a refusal, or no connection to send it on, is
    /// 没发出去 under it, with 重发 (the same id and references; a picture cleared meanwhile goes
    /// up again, as below).
    func submit(_ words: String, _ drafts: [Draft], botId: String, sessionId: String, submission: String,
                again: Bool, mode: SendMode = .queue) async {
        let refs = drafts.compactMap(\.ref).joined(separator: "\n")
        var body = [refs, words].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let pictures = drafts.filter { $0.kind == .image }
        if body.isEmpty {
            body = SentNotes.defaultCaption
        }
        var params: [String: JSONValue] = [
            "profile": .string(botId), "session_id": .string(sessionId), "text": .string(body),
            "submission_id": .string(submission),
        ]
        if !pictures.isEmpty {
            params["attachments"] = .array(pictures.compactMap { picture in
                picture.path.map { ["path": .string($0), "mime": .string(picture.mime)] }
            })
        }
        deliveries.track(submission, botId: botId, text: words, at: Date(), drafts: drafts)
        // just after a reconnect, Hermes takes it once the chat is attached again (AppStore+Reconnect.swift)
        await waitForChat(botId)
        guard gateway.phase == .online, sessions[botId] == sessionId else {
            // it did not go; what it takes is up already, so 重发 sends it once connected
            return deliveries.set(submission, .unsent(nil))
        }
        do {
            try await sendWithMode(params, botId: botId, mode: mode)
            deliveries.arrived(submission)
        } catch GatewayError.rpc(_, let message, let reason) where !again && !pictures.isEmpty && (reason ?? message) == "invalid_params" {
            // a picture staged too long ago was cleared: up again from the Mac's copy, once
            guard let fresh = await uploadAgain(drafts, botId: botId) else {
                return deliveries.set(submission, .unsent("图片要重新上传，可是没传上去"))
            }
            // a new admission, so a new id: the refused one is not asked to change its pictures.
            // The message goes by it from here on, as the turn's end will name it
            let renewed = UUID().uuidString
            deliveries.untrack(submission)
            if let index = chats[botId]?.firstIndex(where: { $0.id == submission }) {
                chats[botId]?[index].id = renewed
            }
            await submit(words, fresh, botId: botId, sessionId: sessionId, submission: renewed, again: true)
        } catch GatewayError.rpc(_, let message, let reason) {
            deliveries.set(submission, .unsent(DeliveryCheck.refusal(reason) ?? reason ?? message))
        } catch let error as ControlError {
            deliveries.set(submission, .unsent(error.localizedDescription))
        } catch {
            // no answer before the connection went: unsure until the server can say
            deliveries.set(submission, .unsure)
        }
    }

    private func uploadAgain(_ drafts: [Draft], botId: String) async -> [Draft]? {
        guard let client = mediaClient else { return nil }
        var fresh: [Draft] = []
        for var draft in drafts {
            if draft.kind == .image {
                guard let hash = draft.sha256, let file = await media.disk.file(hash),
                      let data = await Task.detached(operation: { try? Data(contentsOf: file) }).value,
                      let path = try? await client.uploadPicture(data, name: draft.name, mime: draft.mime, profile: botId,
                                                                 progress: { _ in })
                else { return nil }
                draft.path = path
                await media.disk.remember(sourceKey(path, botId: botId), hash: hash)
            }
            fresh.append(draft)
        }
        return fresh
    }

    // MARK: the transcript

    /// A user row of the transcript: the words you typed, and what came with them (SentNotes).
    static func userItem(id: String, at: Date, text: String) -> ChatItem {
        let parsed = SentNotes.parse(text)
        return ChatItem(id: id, role: .user, at: at, text: parsed.text, media: parsed.media)
    }

    /// A finished tool call's picture (`tool.complete`'s `image_path`). The transcript will not
    /// keep it and Hermes clears its screenshots after a day, so it is remembered and fetched now.
    func toolFinished(_ payload: JSONValue, botId: String) {
        guard let call = payload["tool_id"]?.string, let path = ToolPicture.path(in: payload) else { return }
        let item = "tool-\(call)"
        media.addShot(path, key: "\(botId)|\(item)")
        let disk = media.disk
        let key = shotKey(botId, item)
        Task {
            await disk.rememberShot(key, path: path)
            _ = await loadPicture(ChatMedia(serverPath: path), botId: botId, maxPixel: Self.shotPixels)
        }
    }

    /// The pictures of a tool row: live ones, or those the Mac remembers for it.
    func toolShots(_ botId: String, _ itemId: String) -> [String] {
        media.toolShots["\(botId)|\(itemId)"] ?? []
    }

    func lookUpToolShots(_ botId: String, _ itemIds: [String]) async {
        for itemId in itemIds {
            let key = "\(botId)|\(itemId)"
            guard media.toolShots[key] == nil, !media.lookedUp.contains(key) else { continue }
            media.lookedUp.insert(key)
            let paths = await media.disk.shots(shotKey(botId, itemId))
            if !paths.isEmpty {
                media.setShots(paths, key: key)
            }
        }
    }

    // MARK: pictures on screen

    enum PictureLoad {
        case shown(Picture)
        /// A web picture: fetched once you ask.
        case waiting
        /// Not on the server any more, nor on the Mac.
        case gone
        case failed(String)
    }

    /// A picture's bytes: the Mac's copy, or bytes just had.
    nonisolated enum PictureBytes: Sendable {
        case file(URL)
        case data(Data)
        case waiting
        case gone
        case failed(String)
    }

    /// A chat's picture at most `maxPixel` on its long edge: decoded already, the Mac's copy, the
    /// server's, or the web's once you asked. `keep` marks one you sent. However many rows and
    /// sizes ask for a picture at once, its bytes are fetched once: a screenshot fetched ahead and
    /// its row on screen would otherwise both ask a server that hands it out only for a while.
    func loadPicture(_ item: ChatMedia, botId: String, maxPixel: Int, keep: Bool = false, web: Bool = false) async -> PictureLoad {
        let source = mediaKey(item, botId: botId)
        let key = "\(source)|\(maxPixel)"
        if let picture = media.decodedPicture(key) {
            return .shown(picture)
        }
        if !live, let picture = await Task.detached(operation: { DemoPictures.picture(item.name) }).value {
            media.keepDecoded(picture, key: key)
            return .shown(picture)
        }
        let fetch: Task<PictureBytes, Never>
        if let running = media.fetches[source] {
            fetch = running
        } else {
            fetch = Task { await self.pictureBytes(item, botId: botId, keep: keep, web: web) }
            media.fetches[source] = fetch
        }
        let bytes = await fetch.value
        if media.fetches[source] == fetch {
            media.fetches[source] = nil
        }
        let picture: Picture?
        switch bytes {
        case .file(let file):
            picture = await Task.detached(operation: { Pictures.decode(file: file, maxPixel: maxPixel) }).value
        case .data(let data):
            picture = await Task.detached(operation: { Pictures.decode(data, maxPixel: maxPixel) }).value
        case .waiting:
            return .waiting
        case .gone:
            return .gone
        case .failed(let reason):
            return .failed(reason)
        }
        guard let picture else { return .failed(MediaError.notPicture.localizedDescription) }
        media.keepDecoded(picture, key: key)
        return .shown(picture)
    }

    private func pictureBytes(_ item: ChatMedia, botId: String, keep: Bool, web: Bool) async -> PictureBytes {
        if let hash = await cachedHash(item, botId: botId), let file = await media.disk.file(hash) {
            if keep {
                await media.disk.keep(hash)
            }
            return .file(file)
        }
        if let url = item.url {
            if url.scheme == "data" {
                guard let bytes = MediaClient.decodeDataURL(url.absoluteString), bytes.count <= 20 * 1024 * 1024 else {
                    return .failed(MediaError.notPicture.localizedDescription)
                }
                return .data(bytes)
            }
            guard web || media.showWebPictures else { return .waiting }
            do {
                let bytes = try await Self.fetchWebPicture(url)
                let hash = await media.disk.store(bytes, name: item.name)
                await media.disk.remember(url.absoluteString, hash: hash)
                return .data(bytes)
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        guard let path = item.path, live, let client = mediaClient else { return .gone }
        do {
            let bytes = try await client.picture(at: path, profile: botId, session: sessions[botId])
            let hash = await media.disk.store(bytes, name: item.name, kept: keep)
            await media.disk.remember(sourceKey(path, botId: botId), hash: hash)
            return .data(bytes)
        } catch MediaError.gone {
            return .gone
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Where the Mac's copy is: by the bytes' hash, or by where it came from.
    private func cachedHash(_ item: ChatMedia, botId: String) async -> String? {
        if let hash = item.sha256, await media.disk.file(hash) != nil {
            return hash
        }
        if let path = item.path, let hash = await media.disk.source(sourceKey(path, botId: botId)) {
            return hash
        }
        if let url = item.url, url.scheme != "data" {
            return await media.disk.source(url.absoluteString)
        }
        return nil
    }

    /// A web picture, as privately as it can be had: no cookies, no referrer, `image/*` only and
    /// no SVG, 20 MB at most, never from this Mac or its network, not even by a redirect
    /// (WebRedirects). Off the main thread.
    private nonisolated static func fetchWebPicture(_ url: URL) async throws -> Data {
        guard isWeb(url) else { throw MediaError.localAddress }
        return try await Task.detached(priority: .userInitiated) {
            let session = URLSession(configuration: .ephemeral, delegate: WebRedirects(), delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.httpShouldHandleCookies = false
            request.setValue("image/*", forHTTPHeaderField: "Accept")
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                // a redirect WebRedirects did not follow
                throw (300..<400).contains(status) ? MediaError.localAddress : MediaError.refused(status, "")
            }
            if let final = http.url?.host, isLocal(final) {
                throw MediaError.localAddress
            }
            let type = http.mimeType?.lowercased() ?? ""
            guard type.hasPrefix("image/"), !type.contains("svg") else { throw MediaError.notPicture }
            let limit = 20 * 1024 * 1024
            guard http.expectedContentLength <= Int64(limit) else { throw MediaError.tooLarge("20 MB") }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > limit { throw MediaError.tooLarge("20 MB") }
            }
            return data
        }.value
    }

    /// An http(s) address out on the web.
    nonisolated static func isWeb(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", let host = url.host else { return false }
        return !isLocal(host)
    }

    /// This Mac, its network, and names that only mean something there.
    nonisolated static func isLocal(_ host: String) -> Bool {
        let name = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if name == "localhost" || name.hasSuffix(".localhost") || name.hasSuffix(".local") || name.hasSuffix(".internal")
            || name.hasSuffix(".lan") || name.hasSuffix(".home.arpa") || !name.contains(".") || name.contains(":") {
            return true
        }
        let parts = name.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, name.allSatisfy({ $0.isNumber || $0 == "." }) else { return false }
        switch (parts[0], parts[1]) {
        case (0, _), (10, _), (127, _), (169, 254), (192, 168), (172, 16...31), (100, 64...127): return true
        default: return false
        }
    }

    // MARK: files

    enum FileCheck: Equatable {
        case present(Int?)
        case gone
        /// No server to ask (the demo, offline).
        case unknown
    }

    /// Whether the file is to be had, and how big it is.
    func checkFile(_ item: ChatMedia, botId: String) async -> FileCheck {
        if let hash = await cachedHash(item, botId: botId), let file = await media.disk.file(hash) {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            return .present(item.size ?? size)
        }
        guard live, let client = mediaClient, let path = item.path else { return .unknown }
        do {
            return .present(try await client.check(path, profile: botId, session: sessions[botId]).size ?? item.size)
        } catch MediaError.gone {
            return .gone
        } catch {
            return .unknown
        }
    }

    /// The name a file had on this Mac when you sent it: Hermes renames a staged one in ASCII.
    func localName(_ item: ChatMedia, botId: String) async -> String? {
        guard let hash = await cachedHash(item, botId: botId) else { return nil }
        return await media.disk.name(hash)
    }

    /// The file in the Mac's cache, fetched first when it is not there yet; its hash.
    func localCopy(_ item: ChatMedia, botId: String) async throws -> String {
        if let hash = await cachedHash(item, botId: botId), await media.disk.file(hash) != nil {
            return hash
        }
        guard live, let client = mediaClient, let path = item.path else { throw MediaError.gone }
        let temporary = try await client.download(path, profile: botId, session: sessions[botId])
        let hash = try await media.disk.adopt(temporary, name: item.name)
        await media.disk.remember(sourceKey(path, botId: botId), hash: hash)
        return hash
    }

    /// Into Downloads, opened with its app unless `open` is false (⌥-click). Screenshot and test
    /// runs keep it in their own folder and open nothing.
    @discardableResult
    func saveFile(_ item: ChatMedia, botId: String, open: Bool) async throws -> URL {
        let key = mediaKey(item, botId: botId)
        if let saved = media.saved[key], FileManager.default.fileExists(atPath: saved.path) {
            if open && !LaunchOptions.current.snapshot {
                _ = NSWorkspace.shared.open(saved)
            }
            return saved
        }
        let hash = try await localCopy(item, botId: botId)
        let url = try await media.disk.export(hash, name: Self.displayName(item.name), to: Self.downloads)
        media.markSaved(url, key: key)
        if open && !LaunchOptions.current.snapshot {
            _ = NSWorkspace.shared.open(url)
        }
        return url
    }

    func revealFile(_ item: ChatMedia, botId: String) async throws {
        let url = try await saveFile(item, botId: botId, open: false)
        if !LaunchOptions.current.snapshot {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// For Quick Look: the Mac's copy under the file's own name.
    func previewURL(_ item: ChatMedia, botId: String) async -> URL? {
        guard let hash = try? await localCopy(item, botId: botId) else { return nil }
        return await media.disk.preview(hash, name: Self.displayName(item.name))
    }

    private static var downloads: URL {
        if LaunchOptions.current.snapshot {
            return MediaDisk.location(snapshot: true).deletingLastPathComponent().appendingPathComponent("Downloads", isDirectory: true)
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }
}

/// A web picture's redirects are followed on the web only: none to this Mac or its network, none
/// off http(s). The first address is checked before the request goes (fetchWebPicture).
nonisolated final class WebRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        if let url = request.url, AppStore.isWeb(url) {
            completionHandler(request)
        } else {
            completionHandler(nil)
        }
    }
}
