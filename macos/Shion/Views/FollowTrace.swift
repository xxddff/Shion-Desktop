import Foundation

/// TEMPORARY, for the runs that look into ComposeTests step 2 (runs 208 and 209: a reply left
/// under the composer). What the transcript's following did and why, a line each, in a file the
/// run keeps (ci/export_shots.sh). Only under UI tests (`-ShionSnapshot YES`). Lines are kept in
/// memory and written from another thread, so that writing them down changes little of when
/// things happen.
nonisolated enum FollowTrace {
    private static let path = "/tmp/shion-follow-trace.log"
    private static let lock = NSLock()
    private static let started = Date()
    nonisolated(unsafe) private static var pending: [String] = []
    nonisolated(unsafe) private static var last = ""
    private static let on: Bool = {
        guard UserDefaults.standard.bool(forKey: "ShionSnapshot") else { return false }
        FileManager.default.createFile(atPath: path, contents: nil)
        writeLater()
        return true
    }()

    static func log(_ text: @autoclosure () -> String) {
        guard on else { return }
        let line = String(format: "%9.3f ", Date().timeIntervalSince(started)) + text()
        lock.lock()
        pending.append(line)
        lock.unlock()
    }

    /// The same, unless it is what was last said this way: for what is asked at every layout.
    static func logChange(_ text: @autoclosure () -> String) {
        guard on else { return }
        let words = text()
        lock.lock()
        let same = words == last
        last = words
        lock.unlock()
        if !same {
            log(words)
        }
    }

    /// A number as the log shows it.
    static func n(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private static func writeLater() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            lock.lock()
            let lines = pending
            pending = []
            lock.unlock()
            if !lines.isEmpty, let handle = FileHandle(forWritingAtPath: path) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
                try? handle.close()
            }
            writeLater()
        }
    }
}
