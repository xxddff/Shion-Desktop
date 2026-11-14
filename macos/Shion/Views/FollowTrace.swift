import Foundation

/// TEMPORARY, for one CI run (ComposeTests step 2, runs 208 and 209: a reply left under the
/// composer). What the transcript's following did and why, a line each, in a file the run keeps
/// (ci/export_shots.sh). Only under UI tests (`-ShionSnapshot YES`).
enum FollowTrace {
    private static let started = Date()
    private static let handle: FileHandle? = {
        guard UserDefaults.standard.bool(forKey: "ShionSnapshot") else { return nil }
        let path = "/tmp/shion-follow-trace.log"
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()

    static func log(_ text: @autoclosure () -> String) {
        guard let handle else { return }
        let seconds = Date().timeIntervalSince(started)
        let line = String(format: "%9.3f ", seconds) + text() + "\n"
        try? handle.write(contentsOf: Data(line.utf8))
    }

    /// A number as the log shows it.
    static func n(_ value: CGFloat) -> String {
        String(format: "%.1f", Double(value))
    }
}
