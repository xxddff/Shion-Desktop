import Foundation

/// What the Mac's media cache holds (MediaDisk.swift), kept as JSON beside the files: each file by
/// the SHA-256 of its bytes, where each came from, and the pictures tool calls made.
nonisolated struct MediaIndex: Codable, Sendable, Equatable {
    struct Entry: Codable, Sendable, Equatable {
        /// `<sha256>.<extension>` in the cache folder.
        var file: String
        var size: Int
        /// Last shown or sent, in seconds since 1970.
        var used: Double
        /// A picture you sent: Hermes clears its copy after about a day, so this one stays,
        /// whatever the limit.
        var kept: Bool
        var name: String
    }

    struct Usage: Sendable, Equatable {
        /// Fetched from the server or the web: dropped oldest first past the limit.
        var fetched: Int
        /// Pictures you sent.
        var kept: Int
    }

    var entries: [String: Entry] = [:]
    /// `server|profile|session|path` (session only for a relative path) or a web address → SHA-256.
    var sources: [String: String] = [:]
    /// `server|profile|tool item id` → the server paths of the pictures that call made or looked
    /// at, which Hermes's transcript does not keep.
    var shots: [String: [String]] = [:]

    var usage: Usage {
        entries.values.reduce(into: Usage(fetched: 0, kept: 0)) { total, entry in
            if entry.kept {
                total.kept += entry.size
            } else {
                total.fetched += entry.size
            }
        }
    }

    /// Drops what was used longest ago until the files not kept fit in `limit`. Returns the files
    /// to delete.
    mutating func trim(to limit: Int) -> [String] {
        var total = usage.fetched
        guard total > limit else { return [] }
        var dropped: [String] = []
        for (hash, entry) in entries.filter({ !$0.value.kept }).sorted(by: { $0.value.used < $1.value.used }) {
            guard total > limit else { break }
            total -= entry.size
            entries[hash] = nil
            dropped.append(entry.file)
        }
        forgetSources()
        return dropped
    }

    /// Forgets the fetched files, and the pictures you sent too when `keptToo`. Returns the files to
    /// delete.
    mutating func clear(keptToo: Bool) -> [String] {
        let gone = entries.filter { keptToo || !$0.value.kept }
        for hash in gone.keys {
            entries[hash] = nil
        }
        forgetSources()
        return gone.values.map(\.file)
    }

    /// Sources whose bytes are no longer here point nowhere.
    private mutating func forgetSources() {
        sources = sources.filter { entries[$0.value] != nil }
    }
}
