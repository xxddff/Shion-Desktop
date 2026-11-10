import CryptoKit
import Foundation

/// The Mac's copy of the chats' pictures and files, by content: `<sha256>.<extension>` under
/// ~/Library/Caches/dev.shion.Shion/media, with an index of where each came from (MediaIndex).
/// Hermes clears most of what it keeps for a chat after about a day, and its transcript forgets
/// a tool call's picture, so this copy is what the chat shows later. Not URLCache: that keys by
/// address, which would hit across credentials and cannot be cleared by chat. Screenshot and test
/// runs get a fresh folder of their own.
actor MediaDisk {
    /// What the fetched files may take before the ones used longest ago go; pictures you sent stay.
    static let limit = 1024 * 1024 * 1024

    let folder: URL
    private var index: MediaIndex
    private var saving: Task<Void, Never>?

    init(folder: URL) {
        self.folder = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let saved = try? Data(contentsOf: folder.appendingPathComponent("index.json"))
        index = saved.flatMap { try? JSONDecoder().decode(MediaIndex.self, from: $0) } ?? MediaIndex()
    }

    /// Where the cache lives: the user's caches, or a folder of the run's own.
    nonisolated static func location(snapshot: Bool) -> URL {
        if snapshot {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("Shion-snapshot-\(ProcessInfo.processInfo.processIdentifier)/media", isDirectory: true)
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("dev.shion.Shion/media", isDirectory: true)
    }

    // MARK: files

    /// Keeps the bytes; returns their SHA-256.
    @discardableResult
    func store(_ data: Data, name: String, kept: Bool = false) -> String {
        let hash = Self.hash(data)
        let file = Self.fileName(hash, name)
        let url = folder.appendingPathComponent(file)
        if index.entries[hash] == nil || !FileManager.default.fileExists(atPath: url.path) {
            try? data.write(to: url, options: .atomic)
        }
        add(hash, file: file, size: data.count, name: name, kept: kept)
        return hash
    }

    /// Moves a downloaded file in; returns its SHA-256.
    func adopt(_ file: URL, name: String) throws -> String {
        let hash = try Self.hash(file: file)
        let target = folder.appendingPathComponent(Self.fileName(hash, name))
        if FileManager.default.fileExists(atPath: target.path) {
            try? FileManager.default.removeItem(at: file)
        } else {
            try FileManager.default.moveItem(at: file, to: target)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int) ?? 0
        add(hash, file: target.lastPathComponent, size: size, name: name, kept: false)
        return hash
    }

    /// The file with these bytes, if the cache still has it.
    func file(_ hash: String) -> URL? {
        guard var entry = index.entries[hash] else { return nil }
        let url = folder.appendingPathComponent(entry.file)
        guard FileManager.default.fileExists(atPath: url.path) else {
            index.entries[hash] = nil
            scheduleSave()
            return nil
        }
        entry.used = Date().timeIntervalSince1970
        index.entries[hash] = entry
        scheduleSave()
        return url
    }

    func name(_ hash: String) -> String? {
        index.entries[hash]?.name
    }

    /// A picture you sent: kept past the limit.
    func keep(_ hash: String) {
        guard index.entries[hash]?.kept == false else { return }
        index.entries[hash]?.kept = true
        scheduleSave()
    }

    /// A link to the file under its own name, for Quick Look's title.
    func preview(_ hash: String, name: String) -> URL? {
        guard let source = file(hash) else { return nil }
        let folder = self.folder.appendingPathComponent("preview/\(hash)", isDirectory: true)
        let target = folder.appendingPathComponent(Self.safeName(name, hash))
        if FileManager.default.fileExists(atPath: target.path) { return target }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            try FileManager.default.linkItem(at: source, to: target)
        } catch {
            try? FileManager.default.copyItem(at: source, to: target)
        }
        return FileManager.default.fileExists(atPath: target.path) ? target : source
    }

    /// A copy in `destination` (the Downloads folder) under the file's name, numbered when taken.
    func export(_ hash: String, name: String, to destination: URL) throws -> URL {
        guard let source = file(hash) else { throw MediaError.gone }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let base = Self.safeName(name, hash)
        let stem = (base as NSString).deletingPathExtension
        let ext = (base as NSString).pathExtension
        var target = destination.appendingPathComponent(base)
        var number = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = destination.appendingPathComponent(ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)")
            number += 1
        }
        try FileManager.default.copyItem(at: source, to: target)
        return target
    }

    // MARK: where things came from

    func source(_ key: String) -> String? {
        guard let hash = index.sources[key], index.entries[hash] != nil else { return nil }
        return hash
    }

    func remember(_ key: String, hash: String) {
        guard index.sources[key] != hash else { return }
        index.sources[key] = hash
        scheduleSave()
    }

    func shots(_ key: String) -> [String] {
        index.shots[key] ?? []
    }

    func rememberShot(_ key: String, path: String) {
        guard index.shots[key]?.contains(path) != true else { return }
        index.shots[key, default: []].append(path)
        scheduleSave()
    }

    // MARK: size

    func usage() -> MediaIndex.Usage {
        index.usage
    }

    func clear(keptToo: Bool) {
        for file in index.clear(keptToo: keptToo) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
        }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("preview"))
        scheduleSave()
    }

    private func add(_ hash: String, file: String, size: Int, name: String, kept: Bool) {
        let previous = index.entries[hash]
        index.entries[hash] = MediaIndex.Entry(file: file, size: size, used: Date().timeIntervalSince1970,
                                               kept: kept || previous?.kept == true, name: previous?.name ?? name)
        for dropped in index.trim(to: Self.limit) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(dropped))
        }
        scheduleSave()
    }

    /// The index goes to disk a moment after the last change, not on every one.
    private func scheduleSave() {
        saving?.cancel()
        saving = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: folder.appendingPathComponent("index.json"), options: .atomic)
    }

    // MARK: names

    nonisolated static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func hash(file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// `<sha256>.<extension>`: Quick Look and the image decoder go by the extension.
    private nonisolated static func fileName(_ hash: String, _ name: String) -> String {
        let ext = MediaKinds.fileExtension(name).filter { $0.isLetter || $0.isNumber }
        return ext.isEmpty ? hash : "\(hash).\(ext.prefix(12))"
    }

    /// The name without folders or a leading dot.
    private nonisolated static func safeName(_ name: String, _ hash: String) -> String {
        let last = MediaKinds.fileName(name).replacingOccurrences(of: ":", with: "-")
        let trimmed = last.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return trimmed.isEmpty ? String(hash.prefix(12)) : trimmed
    }
}
