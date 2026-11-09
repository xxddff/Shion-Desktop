import AppKit
import Foundation
import ImageIO
import ObjectiveC

/// rfb/testbed/replay_server.py: plays a recorded session over WebSocket (Xvnc is not on macOS),
/// refusing an upgrade without the Access headers like Cloudflare Access does.
final class ReplayServer {
    let port: Int
    private let process: Process
    private let collector: LineCollector

    init(python: String, script: String, sample: String) throws {
        let collector = LineCollector()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-I", "-B", script, sample,
                             "--require-header", "CF-Access-Client-Id", "--require-header", "CF-Access-Client-Secret"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.standardError
        out.fileHandleForReading.readabilityHandler = { handle in collector.feed(handle.availableData) }
        try process.run()
        guard collector.portReady.wait(timeout: .now() + 15) == .success, let port = collector.port else {
            process.terminate()
            throw URLError(.cannotConnectToHost)
        }
        self.process = process
        self.collector = collector
        self.port = port
    }

    /// stdout lines so far ("port N", "client closed CODE")
    var output: [String] { collector.snapshot }

    func url(then: String) -> URL {
        URL(string: "ws://127.0.0.1:\(port)/api/display/ws?then=\(then)")!
    }

    func stop() {
        if process.isRunning { process.terminate() }
    }
}

final class LineCollector: @unchecked Sendable {
    let portReady = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var buffer = Data()
    private var lines: [String] = []
    private var seenPort: Int?

    var port: Int? {
        lock.lock()
        defer { lock.unlock() }
        return seenPort
    }

    var snapshot: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    func feed(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 10) {
            let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...nl)
            lines.append(line)
            if seenPort == nil, line.hasPrefix("port "), let p = Int(line.dropFirst(5)) {
                seenPort = p
                portReady.signal()
            }
        }
    }
}

/// CPU seconds: this process (getrusage) and WebKit's content processes (ps).
enum CPU {
    static func selfSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    }

    /// pid → CPU seconds for processes whose command contains `name` (e.g. "WebContent").
    static func processes(matching name: String) -> [Int: Double] {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,time=,comm="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        try? ps.run()
        ps.waitUntilExit()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        var out: [Int: Double] = [:]
        for line in text.split(separator: "\n") where line.contains(name) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3, let pid = Int(parts[0]) else { continue }
            out[pid] = seconds(String(parts[1]))
        }
        return out
    }

    /// ps TIME: [[dd-]hh:]mm:ss.ss
    static func seconds(_ time: String) -> Double {
        var total = 0.0
        var rest = time
        if let dash = rest.firstIndex(of: "-") {
            total += (Double(rest[..<dash]) ?? 0) * 86400
            rest = String(rest[rest.index(after: dash)...])
        }
        let parts = rest.split(separator: ":").map { Double($0) ?? 0 }
        for p in parts { total = total * 60 + p }
        return total
    }

    static func webContentTotal() -> Double {
        processes(matching: "WebContent").values.reduce(0, +)
    }
}

/// Compares two pictures (PNG data) pixel by pixel, RGB only.
enum Picture {
    static func rgba(_ data: Data) -> (Int, Int, [UInt8])? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ok = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (w, h, pixels) : nil
    }

    static func compare(_ a: Data, _ b: Data) -> [String: Any] {
        guard let (wa, ha, pa) = rgba(a), let (wb, hb, pb) = rgba(b) else { return ["error": "cannot decode"] }
        guard wa == wb, ha == hb else { return ["error": "size \(wa)x\(ha) vs \(wb)x\(hb)"] }
        var sum = 0, maxDiff = 0, over16 = 0
        for i in stride(from: 0, to: pa.count, by: 4) {
            var worst = 0
            for j in 0..<3 {
                let d = abs(Int(pa[i + j]) - Int(pb[i + j]))
                sum += d
                worst = max(worst, d)
            }
            maxDiff = max(maxDiff, worst)
            if worst > 16 { over16 += 1 }
        }
        let n = wa * ha
        return ["width": wa, "height": ha, "meanAbsDiff": Double(sum) / Double(n * 3),
                "maxDiff": maxDiff, "pixelsOver16": over16, "fractionOver16": Double(over16) / Double(n)]
    }

    static func data(fromDataURL url: String) -> Data? {
        guard let comma = url.firstIndex(of: ",") else { return nil }
        return Data(base64Encoded: String(url[url.index(after: comma)...]))
    }
}

/// What the SDK's WebKit has, read off the Objective-C runtime (nothing is called).
enum Runtime {
    static func describe(_ className: String) -> [String: Any] {
        guard let cls = NSClassFromString(className) else { return ["present": false] }
        func names(_ c: AnyClass?) -> [String] {
            guard let c else { return [] }
            var count: UInt32 = 0
            guard let list = class_copyMethodList(c, &count) else { return [] }
            defer { free(list) }
            return (0..<Int(count)).map { NSStringFromSelector(method_getName(list[$0])) }.sorted()
        }
        var propertyNames: [String] = []
        var count: UInt32 = 0
        if let props = class_copyPropertyList(cls, &count) {
            propertyNames = (0..<Int(count)).map { String(cString: property_getName(props[$0])) }.sorted()
            free(props)
        }
        return ["present": true, "superclass": NSStringFromClass(class_getSuperclass(cls) ?? NSObject.self),
                "instanceMethods": names(cls), "classMethods": names(object_getClass(cls)), "properties": propertyNames]
    }
}

/// An optional as a JSON value (JSONSerialization takes NSNull, not nil).
func orNull(_ value: Any?) -> Any {
    value ?? NSNull()
}

func jsonString(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]) else {
        return "\(value)"
    }
    return String(decoding: data, as: UTF8.self)
}
